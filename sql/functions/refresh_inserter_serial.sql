/*
 *  Refresh insert only table based on serial control field
 */
CREATE FUNCTION refresh_inserter_serial(p_destination text, p_limit integer DEFAULT NULL, p_repull boolean DEFAULT false, p_repull_start bigint DEFAULT NULL, p_repull_end bigint DEFAULT NULL, p_jobmon boolean DEFAULT NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   int := 0; 
v_boundary              int;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_create_sql            text;
v_dblink                int;
v_dblink_name           text;
v_dblink_schema         text;
v_delete_sql            text;
v_dest_schema_name      text;
v_dest_table            text;
v_dest_table_name       text;
v_fetch_sql             text;
v_filter                text[]; 
v_full_refresh          boolean := false;
v_insert_sql            text;
v_job_id                int;
v_jobmon                boolean;
v_jobmon_schema         text;
v_job_name              text;
v_last_fetched          bigint;
v_last_value            bigint;
v_limit                 int;
v_link_exists           boolean;
v_old_search_path       text;
v_remote_sql            text;
v_rowcount              bigint := 0; 
v_source_table          text;
v_sql                   text;
v_src_schema_name       text;
v_src_table_name        text;
v_step_id               int;
v_total                 bigint := 0;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh Inserter: '||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;
IF p_jobmon IS TRUE AND v_jobmon_schema IS NULL THEN
    RAISE EXCEPTION 'p_jobmon parameter set to TRUE, but unable to determine if pg_jobmon extension is installed';
END IF;

v_dblink_name := @extschema@.check_name_length('mimeo_inserter_refresh_'||p_destination);

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||COALESCE(v_jobmon_schema||',', '')||v_dblink_schema||',public'',''false'')';

SELECT source_table
    , dest_table
    , dblink
    , control
    , last_value
    , boundary
    , filter
    , condition
    , batch_limit 
    , jobmon
INTO v_source_table
    , v_dest_table
    , v_dblink
    , v_control
    , v_last_value
    , v_boundary
    , v_filter
    , v_condition
    , v_limit
    , v_jobmon
FROM refresh_config_inserter_serial
WHERE dest_table = p_destination; 
IF NOT FOUND THEN
   RAISE EXCEPTION 'No configuration found for %',v_job_name; 
END IF;  

-- Allow override with parameter
v_jobmon := COALESCE(p_jobmon, v_jobmon);

SELECT schemaname, tablename 
INTO v_dest_schema_name, v_dest_table_name
FROM pg_catalog.pg_tables
WHERE schemaname||'.'||tablename = v_dest_table;

IF v_dest_table_name IS NULL THEN
    RAISE EXCEPTION 'Destination table is missing (%)', v_dest_table;
END IF;

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := @extschema@.concurrent_lock_check(v_dest_table);
IF v_adv_lock = 'false' THEN
    IF v_jobmon THEN
        v_job_id := add_job(v_job_name);
        v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
        PERFORM update_step(v_step_id, 'WARNING','Found concurrent job. Exiting gracefully');
        PERFORM fail_job(v_job_id, 2);
    END IF;
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    RAISE NOTICE 'Found concurrent job. Exiting gracefully';
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

IF v_jobmon THEN
    v_job_id := add_job(v_job_name);
    PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);
END IF;

IF v_jobmon THEN
    v_step_id := add_step(v_job_id,'Building SQL');
END IF;

PERFORM dblink_connect(v_dblink_name, auth(v_dblink));

SELECT array_to_string(p_cols, ',')
    , array_to_string(p_cols_n_types, ',') 
    , p_source_schema_name
    , p_source_table_name
INTO v_cols
    , v_cols_n_types 
    , v_src_schema_name
    , v_src_table_name
FROM manage_dest_table(v_dest_table, NULL, v_dblink_name, p_debug);

IF v_src_table_name IS NULL THEN
    RAISE EXCEPTION 'Source table missing (%)', v_source_table;
END IF;

IF p_limit IS NOT NULL THEN
    v_limit := p_limit;
END IF;

-- Unlike incremental time, there's nothing like CURRENT_TIMESTAMP to base the boundary on. So use the current source max to determine it.
-- For some reason this doesn't like using an int with %L (v_boundary) when making up the format command using dblink
v_sql := format('SELECT boundary FROM dblink(%L, ''SELECT max(%I) - '||v_boundary||' AS boundary FROM %I.%I'') AS (boundary bigint)'
                , v_dblink_name 
                , v_control
                , v_src_schema_name
                , v_src_table_name);
PERFORM gdb(p_debug, v_sql);
EXECUTE v_sql INTO v_boundary;

IF p_repull THEN
    -- Repull ALL data if no start and end values set
    IF p_repull_start IS NULL AND p_repull_end IS NULL THEN
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Request to repull ALL data from source. This could take a while...');
        END IF;
        EXECUTE format('TRUNCATE %I.%I', v_dest_schema_name, v_dest_table_name);
        -- Use upper boundary remote max to avoid edge case of multiple upper boundary values inserting during refresh
        v_remote_sql := format('SELECT '||v_cols||' FROM %I.%I', v_src_schema_name, v_src_table_name);
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
        ELSE
            v_remote_sql := v_remote_sql || ' WHERE ';
        END IF;
        v_remote_sql := format(v_remote_sql || '%I < %L', v_control, v_boundary);
    ELSE
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Request to repull data from '||COALESCE(p_repull_start, '0')||' to '||COALESCE(p_repull_end, v_boundary));
        END IF;
        PERFORM gdb(p_debug,'Request to repull data from '||COALESCE(p_repull_start, '0')||' to '||COALESCE(p_repull_end, v_boundary));
        v_remote_sql := format('SELECT '||v_cols||' FROM %I.%I', v_src_schema_name, v_src_table_name);
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
        ELSE
            v_remote_sql := v_remote_sql || ' WHERE ';
        END IF;
        -- Use upper boundary remote max to avoid edge case of multiple upper boundary values inserting during refresh
        v_remote_sql := v_remote_sql || format('%I > %L AND %I < %L'
                                        , v_control
                                        , COALESCE(p_repull_start::bigint, 0)
                                        , v_control
                                        , COALESCE(p_repull_end::bigint, v_boundary));
        -- Delete the old local data. Use higher than bigint max upper boundary to ensure all old data is deleted
        v_delete_sql := format('DELETE FROM %I.%I WHERE %I > %L AND %I < %L'
                        , v_dest_schema_name
                        , v_dest_table_name
                        , v_control
                        , COALESCE(p_repull_start::bigint, 0)
                        , v_control
                        , COALESCE(p_repull_end::bigint, 9300000000000000000));
        IF v_jobmon THEN
            v_step_id := add_step(v_job_id, 'Deleting current, local data');
        END IF;
        PERFORM gdb(p_debug,'Deleting current, local data: '||v_delete_sql);
        EXECUTE v_delete_sql;
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK', v_rowcount || ' rows removed');
        END IF;
    END IF;
ELSE
    -- does < for upper boundary to keep missing data from happening on rare edge case where a newly inserted row outside the transaction batch
    -- has the exact same timestamp as the previous batch's max timestamp
    v_remote_sql := format('SELECT '||v_cols||' FROM %I.%I', v_src_schema_name, v_src_table_name);
    IF v_condition IS NOT NULL THEN
        v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
    ELSE
        v_remote_sql := v_remote_sql || ' WHERE ';
    END IF;
    v_remote_sql := v_remote_sql || format('%I > %L AND %I < %L ORDER BY %I ASC LIMIT '||COALESCE(v_limit::text, 'ALL')
                                    , v_control
                                    , v_last_value
                                    , v_control
                                    , v_boundary
                                    , v_control);

    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);
    END IF;
    PERFORM gdb(p_debug,'Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);

END IF;

EXECUTE 'CREATE TEMP TABLE mimeo_refresh_inserter_temp ('||v_cols_n_types||')';
PERFORM gdb(p_debug, 'v_remote_sql: '||COALESCE(v_remote_sql, '<NULL>'));
PERFORM dblink_open(v_dblink_name, 'mimeo_cursor', v_remote_sql);
IF v_jobmon THEN
    v_step_id := add_step(v_job_id, 'Inserting new records into local table');
END IF;
v_rowcount := 0;
v_total := 0;
LOOP
    v_fetch_sql := 'INSERT INTO mimeo_refresh_inserter_temp ('||v_cols||') 
        SELECT '||v_cols||' FROM dblink_fetch('||quote_literal(v_dblink_name)||', ''mimeo_cursor'', 50000) AS ('||v_cols_n_types||')';
    EXECUTE v_fetch_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    v_total := v_total + coalesce(v_rowcount, 0);
    EXECUTE format('SELECT max(%I) FROM mimeo_refresh_inserter_temp', v_control) INTO v_last_fetched;
    IF v_limit IS NULL THEN -- insert into the real table in batches if no limit to avoid excessively large temp tables
        EXECUTE format('INSERT INTO %I.%I ('||v_cols||') SELECT '||v_cols||' FROM mimeo_refresh_inserter_temp', v_dest_schema_name, v_dest_table_name);
        TRUNCATE mimeo_refresh_inserter_temp;
    END IF;
    EXIT WHEN v_rowcount = 0;
    PERFORM gdb(p_debug,'Fetching rows in batches: '||v_total||' done so far. Last fetched: '||v_last_fetched);
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'PENDING', 'Fetching rows in batches: '||v_total||' done so far. Last fetched: '||v_last_fetched);
    END IF;
END LOOP;
PERFORM dblink_close(v_dblink_name, 'mimeo_cursor');
IF v_jobmon THEN
    PERFORM update_step(v_step_id, 'OK','Rows fetched: '||v_total);
END IF;

IF v_limit IS NULL THEN
    -- nothing else to do
ELSE
    -- When using batch limits, entire batch must be pulled to temp table before inserting to real table to catch edge cases 
    IF v_jobmon THEN
        v_step_id := add_step(v_job_id,'Checking for batch limit issues');
    END IF;
    PERFORM gdb(p_debug, 'Checking for batch limit issues');
    -- Not recommended that the batch actually equal the limit set if possible. Handle all edge cases to keep data consistent
    IF v_total >= v_limit THEN
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'WARNING','Row count fetched equal to or greater than limit set: '||v_limit||'. Recommend increasing batch limit if possible.');
        END IF;
        PERFORM gdb(p_debug, 'Row count fetched equal to or greater than limit set: '||v_limit||'. Recommend increasing batch limit if possible.'); 
        EXECUTE format('SELECT max(%I) FROM mimeo_refresh_inserter_temp', v_control) INTO v_last_value;
        IF v_jobmon THEN
            v_step_id := add_step(v_job_id, 'Removing high boundary rows from this batch to avoid missing data');       
        END IF;
        EXECUTE format('DELETE FROM mimeo_refresh_inserter_temp WHERE %I = %L', v_control, v_last_value);
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK', 'Removed '||v_rowcount||' rows. Batch now contains '||v_limit - v_rowcount||' records');
        END IF;
        PERFORM gdb(p_debug, 'Removed '||v_rowcount||' rows from batch. Batch table now contains '||v_limit - v_rowcount||' records');
        v_batch_limit_reached = 2;
        v_total := v_total - v_rowcount;
        IF (v_limit - v_rowcount) < 1 THEN
            IF v_jobmon THEN
                v_step_id := add_step(v_job_id, 'Reached inconsistent state');
                PERFORM update_step(v_step_id, 'CRITICAL', 'Batch contained max rows ('||v_limit||') or greater and all contained the same serial value. Unable to guarentee rows will ever be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            END IF;
            PERFORM gdb(p_debug, 'Batch contained max rows desired ('||v_limit||') or greater and all contained the same serial value. Unable to guarentee rows will be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            v_batch_limit_reached = 3;
        END IF;
    ELSE
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','No issues found');
        END IF;
        PERFORM gdb(p_debug, 'No issues found');
    END IF;

    IF v_batch_limit_reached <> 3 THEN
        IF v_jobmon THEN
            v_step_id := add_step(v_job_id,'Inserting new records into local table');
        END IF;
        EXECUTE format('INSERT INTO %I.%I ('||v_cols||') SELECT '||v_cols||' FROM mimeo_refresh_inserter_temp', v_dest_schema_name, v_dest_table_name);
        IF v_jobmon THEN
            PERFORM update_step(v_step_id, 'OK','Inserted '||v_total||' records');
        END IF;
        PERFORM gdb(p_debug, 'Inserted '||v_total||' records');
    END IF;

END IF; -- end v_limit IF

IF v_batch_limit_reached <> 3 THEN
    IF v_jobmon THEN
        v_step_id := add_step(v_job_id, 'Setting next lower boundary');
    END IF;
    EXECUTE format('SELECT max(%I) FROM %I.%I', v_control, v_dest_schema_name, v_dest_table_name) INTO v_last_value;
    UPDATE refresh_config_inserter_serial SET last_value = coalesce(v_last_value, 0), last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
    IF v_jobmon THEN
        PERFORM update_step(v_step_id, 'OK','Lower boundary value is: '|| coalesce(v_last_value, 0));
        PERFORM gdb(p_debug, 'Lower boundary value is: '||coalesce(v_last_value, 0));
    END IF;
END IF;

DROP TABLE IF EXISTS mimeo_refresh_inserter_temp;

PERFORM dblink_disconnect(v_dblink_name);

IF v_jobmon THEN
    IF v_batch_limit_reached = 0 THEN
        PERFORM close_job(v_job_id);
    ELSIF v_batch_limit_reached = 2 THEN
        -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
        -- Preventive warning to keep replication from falling behind.
        PERFORM fail_job(v_job_id, 2);
    ELSIF v_batch_limit_reached = 3 THEN
        -- Really bad. Critical alert!
        PERFORM fail_job(v_job_id);
    END IF;
END IF;

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

EXCEPTION
    WHEN QUERY_CANCELED THEN
        EXECUTE 'SELECT '||v_dblink_schema||'.dblink_get_connections() @> ARRAY['||quote_literal(v_dblink_name)||']' INTO v_link_exists;
        IF v_link_exists THEN
            EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect('||quote_literal(v_dblink_name)||')';
        END IF;
        RAISE EXCEPTION '%', SQLERRM;    
    WHEN OTHERS THEN
        EXECUTE 'SELECT '||v_dblink_schema||'.dblink_get_connections() @> ARRAY['||quote_literal(v_dblink_name)||']' INTO v_link_exists;
        IF v_link_exists THEN
            EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect('||quote_literal(v_dblink_name)||')';
        END IF;
        IF v_jobmon THEN
            IF v_job_id IS NULL THEN
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_job(''Refresh Inserter: '||p_destination||''')' INTO v_job_id;
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_step('||v_job_id||', ''EXCEPTION before job logging started'')' INTO v_step_id;
            END IF;
            IF v_step_id IS NULL THEN
                EXECUTE 'SELECT '||v_jobmon_schema||'.add_step('||v_job_id||', ''EXCEPTION before first step logged'')' INTO v_step_id;
            END IF;
                  EXECUTE 'SELECT '||v_jobmon_schema||'.update_step('||v_step_id||', ''CRITICAL'', ''ERROR: '||COALESCE(SQLERRM,'unknown')||''')';
            EXECUTE 'SELECT '||v_jobmon_schema||'.fail_job('||v_job_id||')';
        END IF;
        RAISE EXCEPTION '%', SQLERRM;    
END
$$;

