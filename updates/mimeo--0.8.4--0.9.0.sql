-- IMPORTANT NOTE: This update requires the new 1.0.0 version of pg_jobmon that was shortly before this update. Please update pg_jobmon before updating mimeo!
-- Remove explicit calls to pg_jobmon schema. Would cause failure if pg_jobmon was installed in any schema other than "jobmon".
-- Changed refresh functions that call dblink multiple times to use only a single, named connection instead of a new unnamed one for every call. Also ensured named connections are unique to each tables' refresh job to prevent conflicts.
-- Fix repull option in dml to clear the queue table on the source database.
-- Reaching the batch limit for any refresh function will now cause a level 2 (warning) alert to be triggered in pg_jobmon. Helps to prevent replication falling behind by giving warning that a higher rate of change is possibly happening on the source than the destination can handle.
-- Changed all references to "pk_field" variable and column name to "pk_name". Was bad coding practice on my part using both names for the same thing throughout development. Changes visible to users are the optional argument name in updater/dml/logdel_maker & the column name in the refresh_config_updater/dml/logdel tables.
-- Added pgTAP tests for data repull options

ALTER TABLE @extschema@.refresh_config_updater RENAME pk_field TO pk_name;
ALTER TABLE @extschema@.refresh_config_dml RENAME pk_field TO pk_name;
ALTER TABLE @extschema@.refresh_config_logdel RENAME pk_field TO pk_name;

/*
 *  Refresh based on DML (Insert, Update, Delete)
 */
CREATE OR REPLACE FUNCTION refresh_dml(p_destination text, p_limit int default NULL, p_repull boolean DEFAULT false, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   boolean := false;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_create_f_sql          text;
v_create_q_sql          text;
v_dblink                int;
v_dblink_name           text;
v_dblink_schema         text;
v_delete_sql            text;
v_dest_table            text;
v_exec_status           text;
v_field                 text;
v_filter                text[];
v_insert_sql            text;
v_job_id                int;
v_jobmon_schema         text;
v_job_name              text;
v_limit                 int; 
v_old_search_path       text;
v_pk_counter            int;
v_pk_name_csv           text := '';
v_pk_name_type_csv      text := '';
v_pk_name               text[];
v_pk_queue              text := '';
v_pk_queue_where        text := '';
v_pk_type               text[];
v_pk_where              text;
v_remote_f_sql          text;
v_remote_q_sql          text;
v_rowcount              bigint := 0; 
v_source_table          text;
v_step_id               int;
v_tmp_table             text;
v_trigger_delete        text; 
v_trigger_update        text;
v_truncate_remote_q     text;
v_with_update           text;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh DML: '||p_destination;
v_dblink_name := 'mimeo_dml_refresh_'||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||',public'',''false'')';

SELECT source_table
    , dest_table
    , 'tmp_'||replace(dest_table,'.','_')
    , dblink
    , control
    , pk_name
    , pk_type
    , filter
    , condition
    , batch_limit 
FROM refresh_config_dml 
WHERE dest_table = p_destination INTO 
    v_source_table
    , v_dest_table
    , v_tmp_table
    , v_dblink
    , v_control
    , v_pk_name
    , v_pk_type
    , v_filter
    , v_condition
    , v_limit; 
IF NOT FOUND THEN
   RAISE EXCEPTION 'ERROR: no configuration found for %',v_job_name; 
END IF;

v_job_id := add_job(v_job_name);
PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_dml'), hashtext(v_job_name));
IF v_adv_lock = 'false' THEN
    v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    PERFORM update_step(v_step_id, 'OK','Found concurrent job. Exiting gracefully');
    PERFORM close_job(v_job_id);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

v_step_id := add_step(v_job_id,'Building SQL');

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'ERROR: primary key fields in refresh_config_dml must be defined';
END IF;

-- determine column list, column type list
IF v_filter IS NULL THEN 
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND attnum > 0 AND attisdropped is false;
ELSE
    -- ensure all primary key columns are included in any column filters
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(v_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary/unique key for %',v_job_name; 
        END IF;
    END LOOP;
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND ARRAY[attname::text] <@ v_filter AND attnum > 0 AND attisdropped is false;
END IF;    

v_limit = COALESCE(p_limit, v_limit, 10000);

v_pk_name_csv := array_to_string(v_pk_name, ',');
v_pk_counter := 1;
WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
    IF v_pk_counter > 1 THEN
        v_pk_name_type_csv := v_pk_name_type_csv || ', ';
        v_pk_queue := v_pk_queue || ', ';
        v_pk_queue_where := v_pk_queue_where || ' OR ';
    END IF;
    v_pk_name_type_csv := v_pk_name_type_csv ||v_pk_name[v_pk_counter]||' '||v_pk_type[v_pk_counter];
    v_pk_queue := v_pk_queue || v_pk_name[v_pk_counter] || ' as mimeo_q_' || v_pk_name[v_pk_counter];
    v_pk_queue_where := v_pk_queue_where || v_pk_name[v_pk_counter] || ' = mimeo_q_' || v_pk_name[v_pk_counter];
    v_pk_counter := v_pk_counter + 1;
END LOOP;

v_with_update := 'WITH a AS (SELECT '||v_pk_name_csv||' FROM '|| v_control ||' ORDER BY '||v_pk_name_csv||' LIMIT '|| v_limit ||') UPDATE '||v_control||' b SET processed = true FROM a WHERE a.'||v_pk_name[1]||' = b.'||v_pk_name[1];

v_pk_counter := 2;
IF array_length(v_pk_name, 1) > 1 THEN
    v_pk_where := '';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        v_pk_where := v_pk_where || ' AND a.'||v_pk_name[v_pk_counter]||' = b.'||v_pk_name[v_pk_counter];
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
END IF;

IF v_pk_where IS NOT NULL THEN
    v_with_update := v_with_update || v_pk_where;
END IF;
PERFORM gdb(p_debug, v_with_update);

v_trigger_update := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','|| quote_literal(v_with_update)||')';

v_remote_q_sql := 'SELECT DISTINCT '||v_pk_name_csv||' FROM '||v_control||' WHERE processed = true';

IF p_repull THEN
    v_remote_f_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
    IF v_condition IS NOT NULL THEN
        v_remote_f_sql := v_remote_f_sql || ' ' || v_condition;
    END IF;
    v_truncate_remote_q := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','||quote_literal('TRUNCATE TABLE '||v_control)||')';
ELSE
    -- Handles edge case to catch when a multi-column primary/unique key changes the value of a subset of the columns. 
    v_remote_f_sql := 'SELECT '||v_cols||' 
        FROM '||v_source_table||', 
        (SELECT DISTINCT '||v_pk_queue||' FROM '||v_control||' WHERE processed = true) x ';
    IF v_condition IS NOT NULL THEN
        v_remote_f_sql := v_remote_f_sql || ' ' || v_condition ||' AND ';
    ELSE
        v_remote_f_sql := v_remote_f_sql || ' WHERE ';
    END IF;
    v_remote_f_sql := v_remote_f_sql || v_pk_queue_where;

    v_create_q_sql := 'CREATE TEMP TABLE '||v_tmp_table||'_queue AS SELECT '||v_pk_name_csv||'
        FROM dblink('||quote_literal(v_dblink_name)||','||quote_literal(v_remote_q_sql)||') t ('||v_pk_name_type_csv||')';

    v_delete_sql := 'DELETE FROM '||v_dest_table||' a USING '||v_tmp_table||'_queue b WHERE a.'||v_pk_name[1]||'= b.'||v_pk_name[1];
    IF array_length(v_pk_name, 1) > 1 THEN
        v_delete_sql := v_delete_sql || v_pk_where;
    END IF; 

END IF;

v_create_f_sql := 'CREATE TEMP TABLE '||v_tmp_table||'_full AS SELECT '||v_cols||' 
        FROM dblink('||quote_literal(v_dblink_name)||','||quote_literal(v_remote_f_sql)||') t ('||v_cols_n_types||')';

v_insert_sql := 'INSERT INTO '||v_dest_table||'('||v_cols||') SELECT '||v_cols||' FROM '||v_tmp_table||'_full'; 

v_trigger_delete := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','||quote_literal('DELETE FROM '||v_control||' WHERE processed = true')||')'; 

PERFORM update_step(v_step_id, 'OK','Done');

PERFORM dblink_connect(v_dblink_name, auth(v_dblink));

-- update remote entries
v_step_id := add_step(v_job_id,'Updating remote trigger table');
PERFORM gdb(p_debug,v_trigger_update);
EXECUTE v_trigger_update INTO v_exec_status;    
PERFORM update_step(v_step_id, 'OK','Result was '||v_exec_status);

-- create temp tables 
v_step_id := add_step(v_job_id,'Creating full temp table');
IF p_repull THEN
    -- Do truncate of remote queue table here before full data pull is actually started to ensure all new changes are recorded
    PERFORM update_step(v_step_id, 'OK','Request to repull ALL data from source. This could take a while...');
    PERFORM gdb(p_debug, 'Request to repull ALL data from source. This could take a while...');
    EXECUTE v_truncate_remote_q;
END IF;
-- Full table with all insert/update data    
PERFORM gdb(p_debug,v_create_f_sql);
EXECUTE v_create_f_sql;
GET DIAGNOSTICS v_rowcount = ROW_COUNT;
PERFORM gdb(p_debug,'Temp full table row count '||v_rowcount);
IF v_rowcount < 1 THEN 
    PERFORM update_step(v_step_id, 'OK','No new rows found');
ELSE 
    -- remove records from local table 
    IF p_repull THEN
        PERFORM update_step(v_step_id, 'OK','Number of rows to process: '||v_rowcount);
        v_step_id := add_step(v_job_id,'Truncating local table');
        PERFORM gdb(p_debug,'Truncating local table');
        EXECUTE 'TRUNCATE '||v_dest_table;
        PERFORM update_step(v_step_id, 'OK','Done');
    ELSE
        IF v_rowcount < v_limit THEN
            PERFORM update_step(v_step_id, 'OK','Number of rows to process: '||v_rowcount);
        ELSE
            PERFORM update_step(v_step_id, 'WARNING','Row count fetched equal to limit set: '||v_limit||'. Recommend increasing batch limit if possible.');
            v_batch_limit_reached := true;
        END IF;
        EXECUTE v_create_q_sql;
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        PERFORM gdb(p_debug,'Temp queue table row count '||v_rowcount::text);
        v_step_id := add_step(v_job_id,'Deleting records from local table');
        PERFORM gdb(p_debug,v_delete_sql);
        EXECUTE v_delete_sql; 
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        PERFORM gdb(p_debug,'Rows removed from local table before applying changes: '||v_rowcount::text);
        PERFORM update_step(v_step_id, 'OK','Removed '||v_rowcount||' records');
    END IF;

    -- insert records to local table
    v_step_id := add_step(v_job_id,'Inserting new records into local table');
    PERFORM gdb(p_debug,v_insert_sql);
    EXECUTE v_insert_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Rows inserted: '||v_rowcount::text);
    PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');

    -- clean out rows from txn table
    v_step_id := add_step(v_job_id,'Cleaning out rows from txn table');
    PERFORM gdb(p_debug,v_trigger_delete);
    EXECUTE v_trigger_delete INTO v_exec_status;
    PERFORM update_step(v_step_id, 'OK','Result was '||v_exec_status);
END IF;

-- update activity status
v_step_id := add_step(v_job_id,'Updating last_run in config table');
UPDATE refresh_config_dml SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination; 
PERFORM update_step(v_step_id, 'OK','Last run was '||CURRENT_TIMESTAMP);

EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table||'_queue';
EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table||'_full';

PERFORM dblink_disconnect(v_dblink_name);

IF v_batch_limit_reached = false THEN
    PERFORM close_job(v_job_id);
ELSE
    -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
    -- Preventive warning to keep replication from falling behind.
    PERFORM fail_job(v_job_id, 2);
END IF;

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_dml'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF dblink_get_connections() @> ARRAY[v_dblink_name] THEN
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        PERFORM pg_advisory_unlock(hashtext('refresh_dml'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;  
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF v_job_id IS NULL THEN
                v_job_id := add_job('Refresh DML: '||p_destination);
                v_step_id := add_step(v_job_id, 'EXCEPTION before job logging started');
        END IF;
        IF v_step_id IS NULL THEN
            v_step_id := add_step(v_job_id, 'EXCEPTION before first step logged');
        END IF;
        IF dblink_get_connections() @> ARRAY[v_dblink_name] THEN
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        PERFORM update_step(v_step_id, 'CRITICAL', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        PERFORM fail_job(v_job_id);

        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

        PERFORM pg_advisory_unlock(hashtext('refresh_dml'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;
END
$$;


/*
 *  Refresh insert only table based on timestamp control field
 */
CREATE OR REPLACE FUNCTION refresh_inserter(p_destination text, p_limit integer DEFAULT NULL, p_repull boolean DEFAULT false, p_repull_start text DEFAULT NULL, p_repull_end text DEFAULT NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   boolean := false; 
v_boundary              timestamptz;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_create_sql            text;
v_dblink_schema         text;
v_dblink                int;
v_delete_sql            text;
v_dest_table            text;
v_dst_active            boolean;
v_dst_check             boolean;
v_dst_start             int;
v_dst_end               int;
v_filter                text[]; 
v_full_refresh          boolean := false;
v_insert_sql            text;
v_job_id                int;
v_jobmon_schema         text;
v_job_name              text;
v_last_value_sql        text;
v_last_value            timestamptz;
v_limit                 int;
v_now                   timestamptz := now();
v_old_search_path       text;
v_remote_sql            text;
v_rowcount              bigint; 
v_source_table          text;
v_step_id               int;
v_tmp_table             text;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh Inserter: '||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||',public'',''false'')';

v_job_id := add_job(v_job_name);
PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_inserter'), hashtext(v_job_name));
IF v_adv_lock = 'false' THEN
    v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    PERFORM update_step(v_step_id, 'OK','Found concurrent job. Exiting gracefully');
    PERFORM close_job(v_job_id);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

SELECT source_table
    , dest_table
    , 'tmp_'||replace(dest_table,'.','_')
    , dblink
    , control
    , last_value
    , now() - boundary::interval
    , filter
    , condition
    , dst_active
    , dst_start
    , dst_end
    , batch_limit 
FROM refresh_config_inserter WHERE dest_table = p_destination 
INTO v_source_table
    , v_dest_table
    , v_tmp_table
    , v_dblink
    , v_control
    , v_last_value
    , v_boundary
    , v_filter
    , v_condition
    , v_dst_active
    , v_dst_start
    , v_dst_end
    , v_limit; 
IF NOT FOUND THEN
   RAISE EXCEPTION 'ERROR: no configuration found for %',v_job_name; 
END IF;  

-- Do not allow this function to run during DST time change if config option is true. Otherwise will miss data from source
IF v_dst_active THEN
    v_dst_check := @extschema@.dst_change(v_now);
    IF v_dst_check THEN 
        IF to_number(to_char(v_now, 'HH24MM'), '0000') > v_dst_start AND to_number(to_char(v_now, 'HH24MM'), '0000') < v_dst_end THEN
            v_step_id := add_step( v_job_id, 'DST Check');
            PERFORM update_step(v_step_id, 'OK', 'Job CANCELLED - Does not run during DST time change');
            PERFORM close_job(v_job_id);
            PERFORM gdb(p_debug, 'Cannot run during DST time change');
            UPDATE refresh_config_inserter SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            PERFORM pg_advisory_unlock(hashtext('refresh_inserter'), hashtext(v_job_name));
            RETURN;
        END IF;
    END IF;
END IF;

v_step_id := add_step(v_job_id,'Building SQL');

IF v_filter IS NULL THEN 
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND attnum > 0 AND attisdropped is false;
ELSE
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND ARRAY[attname::text] <@ v_filter AND attnum > 0 AND attisdropped is false;
END IF;

v_last_value_sql := 'SELECT max('||v_control||') FROM '||v_tmp_table;
v_limit = COALESCE(p_limit, v_limit, 10000);

-- Repull old data instead of normal new data pull
IF p_repull THEN
    -- Repull ALL data if no start and end values set
    IF p_repull_start IS NULL AND p_repull_end IS NULL THEN
        -- Actual truncate is done after pull to temp table to minimize lock on dest_table
        PERFORM update_step(v_step_id, 'OK','Request to repull ALL data from source. This could take a while...');
        v_full_refresh := true;
        v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition;
        END IF;
    ELSE
        PERFORM update_step(v_step_id, 'OK','Request to repull data from '||COALESCE(p_repull_start, '-infinity')||' to '||COALESCE(p_repull_end, 'infinity'));
        PERFORM gdb(p_debug,'Request to repull data from '||COALESCE(p_repull_start, '-infinity')||' to '||COALESCE(p_repull_end, 'infinity'));
        v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
        ELSE
            v_remote_sql := v_remote_sql || ' WHERE ';
        END IF;
        v_remote_sql := v_remote_sql ||v_control||' > '||quote_literal(COALESCE(p_repull_start, '-infinity'))||' AND '
            ||v_control||' < '||quote_literal(COALESCE(p_repull_end, 'infinity'));
        -- Delete the old local data
        v_delete_sql := 'DELETE FROM '||v_dest_table||' WHERE '||v_control||' > '||quote_literal(COALESCE(p_repull_start, '-infinity'))||' AND '
            ||v_control||' < '||quote_literal(COALESCE(p_repull_end, 'infinity'));
        v_step_id := add_step(v_job_id, 'Deleting current, local data');
        PERFORM gdb(p_debug,'Deleting current, local data: '||v_delete_sql);
        EXECUTE v_delete_sql;
        PERFORM update_step(v_step_id, 'OK','Done');
        -- Set last_value equal to local, real table max instead of temp table (just in case)
        v_last_value_sql := 'SELECT max('||v_control||') FROM '||v_dest_table;
    END IF;
ELSE

    -- does < for upper boundary to keep missing data from happening on rare edge case where a newly inserted row outside the transaction batch
    -- has the exact same timestamp as the previous batch's max timestamp
    v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
    IF v_condition IS NOT NULL THEN
        v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
    ELSE
        v_remote_sql := v_remote_sql || ' WHERE ';
    END IF;
    v_remote_sql := v_remote_sql ||v_control||' > '||quote_literal(v_last_value)||' AND '||v_control||' < '||quote_literal(v_boundary)||' ORDER BY '||v_control||' ASC LIMIT '|| v_limit;

    PERFORM update_step(v_step_id, 'OK','Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);
    PERFORM gdb(p_debug,'Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);

END IF;

v_create_sql := 'CREATE TEMP TABLE '||v_tmp_table||' AS SELECT '||v_cols||' FROM dblink(auth('||v_dblink||'),'||quote_literal(v_remote_sql)||') t ('||v_cols_n_types||')';

v_insert_sql := 'INSERT INTO '||v_dest_table||'('||v_cols||') SELECT '||v_cols||' FROM '||v_tmp_table; 

-- create temp from remote
v_step_id := add_step(v_job_id,'Creating temp table ('||v_tmp_table||') from remote table');
    PERFORM gdb(p_debug,v_create_sql);
    EXECUTE v_create_sql; 
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    -- Do nothing if no new rows
    IF v_rowcount < 1 THEN 
        PERFORM update_step(v_step_id, 'OK','No new rows found');
        EXECUTE 'DROP TABLE IF EXISTS ' || v_tmp_table;
        UPDATE refresh_config_inserter SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
        PERFORM close_job(v_job_id);
        PERFORM gdb(p_debug, 'No new rows found');
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        PERFORM pg_advisory_unlock(hashtext('refresh_inserter'), hashtext(v_job_name));
        RETURN;
    -- Not recommended that the batch actually equal the limit set if possible. Handle all edge cases to keep data consistent
    ELSIF (v_rowcount = v_limit) AND (p_repull = false) THEN
        PERFORM update_step(v_step_id, 'WARNING','Row count fetched equal to limit set: '||v_limit||'. Recommend increasing batch limit if possible.');
        PERFORM gdb(p_debug, 'Row count fetched equal to limit set: '||v_limit||'. Recommend increasing batch limit if possible.'); 
        EXECUTE v_last_value_sql INTO v_last_value;
        v_step_id := add_step(v_job_id, 'Removing high boundary rows from this batch to avoid missing data');       
        EXECUTE 'DELETE FROM '||v_tmp_table||' WHERE '||v_control||' = '||quote_literal(v_last_value);
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        PERFORM update_step(v_step_id, 'OK', 'Removed '||v_rowcount||' rows. Batch now contains '||v_limit - v_rowcount||' records');
        PERFORM gdb(p_debug, 'Removed '||v_rowcount||' rows from batch. Batch table now contains '||v_limit - v_rowcount||' records');
        v_batch_limit_reached = true;
        IF (v_limit - v_rowcount) < 1 THEN
            v_step_id := add_step(v_job_id, 'Reached inconsistent state');
            PERFORM update_step(v_step_id, 'CRITICAL', 'Batch contained max rows ('||v_limit||') and all contained the same timestamp value. Unable to guarentee rows will ever be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            PERFORM gdb(p_debug, 'Batch contained max rows desired ('||v_limit||') and all contained the same timestamp value. Unable to guarentee rows will be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            UPDATE refresh_config_inserter SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
            PERFORM fail_job(v_job_id);
            EXECUTE 'DROP TABLE IF EXISTS ' || v_tmp_table;
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            PERFORM pg_advisory_unlock(hashtext('refresh_inserter'), hashtext(v_job_name));
            RETURN;
        END IF;
    ELSE
        PERFORM update_step(v_step_id, 'OK','Batch contains '||v_rowcount||' records');
        PERFORM gdb(p_debug, 'Batch contains '||v_rowcount||' records');
    END IF;

IF v_full_refresh THEN        
        EXECUTE 'TRUNCATE '||v_dest_table;
END IF;

-- insert
v_step_id := add_step(v_job_id,'Inserting new records into local table');
PERFORM gdb(p_debug,v_insert_sql);
EXECUTE v_insert_sql; 
GET DIAGNOSTICS v_rowcount = ROW_COUNT;
PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');
PERFORM gdb(p_debug, v_rowcount || ' rows added to ' || v_dest_table);

-- Get new last_value
v_step_id := add_step(v_job_id, 'Getting local max control field value for next lower boundary');
PERFORM gdb(p_debug, v_last_value_sql);
EXECUTE v_last_value_sql INTO v_last_value;
PERFORM update_step(v_step_id, 'OK','Max value is: '||v_last_value);
PERFORM gdb(p_debug, 'Max value is: '||v_last_value);

-- update boundries
v_step_id := add_step(v_job_id,'Updating last_value in config');
UPDATE refresh_config_inserter set last_value = v_last_value, last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
PERFORM update_step(v_step_id, 'OK','Done');

EXECUTE 'DROP TABLE IF EXISTS ' || v_tmp_table;

IF v_batch_limit_reached = false THEN
    PERFORM close_job(v_job_id);
ELSE
    -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
    -- Preventive warning to keep replication from falling behind.
    PERFORM fail_job(v_job_id, 2);
END IF;

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_inserter'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        PERFORM pg_advisory_unlock(hashtext('refresh_inserter'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;    
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF v_job_id IS NULL THEN
            v_job_id := add_job('Refresh Inserter: '||p_destination);
            v_step_id := add_step(v_job_id, 'EXCEPTION before job logging started');
        END IF;
        IF v_step_id IS NULL THEN
            v_step_id := add_step(v_job_id, 'EXCEPTION before first step logged');
        END IF;
        PERFORM update_step(v_step_id, 'BAD', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        PERFORM fail_job(v_job_id);

        -- Ensure old search path is reset for the current session
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

        PERFORM pg_advisory_unlock(hashtext('refresh_inserter'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;    
END
$$;


/*
 *  Refresh based on DML (Insert, Update, Delete), but logs all deletes on the destination table
 *  Destination table requires extra column: mimeo_source_deleted timestamptz
 */
CREATE OR REPLACE FUNCTION refresh_logdel(p_destination text, p_limit int default NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   boolean := false;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_create_d_sql          text;
v_create_f_sql          text;
v_create_q_sql          text;
v_dblink                int;
v_dblink_name           text;
v_dblink_schema         text;
v_delete_d_sql          text;
v_delete_f_sql          text;
v_dest_table            text;
v_exec_status           text;
v_field                 text;
v_filter                text[];
v_full_rowcount         bigint := 0;
v_insert_deleted_sql    text;
v_insert_sql            text;
v_job_id                int;
v_jobmon_schema         text;
v_job_name              text;
v_limit                 int; 
v_old_search_path       text;
v_pk_counter            int;
v_pk_name               text[];
v_pk_name_csv           text;
v_pk_name_type_csv      text := '';
v_pk_queue              text := '';
v_pk_queue_where        text := '';
v_pk_type               text[];
v_pk_where              text;
v_remote_d_sql          text;
v_remote_f_sql          text;
v_remote_q_sql          text;
v_rowcount              bigint := 0; 
v_source_table          text;
v_step_id               int;
v_tmp_table             text;
v_trigger_delete        text; 
v_trigger_update        text;
v_with_update           text;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh Log Del: '||p_destination;
v_dblink_name := 'mimeo_logdel_refresh_'||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||',public'',''false'')';

SELECT source_table
    , dest_table
    , 'tmp_'||replace(dest_table,'.','_')
    , dblink
    , control
    , pk_name
    , pk_type
    , filter
    , condition
    , batch_limit 
FROM refresh_config_logdel 
WHERE dest_table = p_destination INTO 
    v_source_table
    , v_dest_table
    , v_tmp_table
    , v_dblink
    , v_control
    , v_pk_name
    , v_pk_type
    , v_filter
    , v_condition
    , v_limit; 
IF NOT FOUND THEN
   RAISE EXCEPTION 'ERROR: no configuration found for %',v_job_name; 
END IF;

v_job_id := add_job(v_job_name);
PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_logdel'), hashtext(v_job_name));
IF v_adv_lock = 'false' THEN
    v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    PERFORM update_step(v_step_id, 'OK','Found concurrent job. Exiting gracefully');
    PERFORM close_job(v_job_id);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

v_step_id := add_step(v_job_id,'Grabbing Boundries, Building SQL');

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'ERROR: primary key fields in refresh_config_logdel must be defined';
END IF;

-- determine column list, column type list
IF v_filter IS NULL THEN 
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',')
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attnum > 0 AND attisdropped is false AND attrelid = p_destination::regclass AND attname != 'mimeo_source_deleted';
ELSE
    -- ensure all primary key columns are included in any column filters
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(v_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary key for %',v_job_name; 
        END IF;
    END LOOP;
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND ARRAY[attname::text] <@ v_filter AND attnum > 0 AND attisdropped is false AND attname != 'mimeo_source_deleted' ;
END IF;    

-- init sql statements 

v_limit = COALESCE(p_limit, v_limit, 10000);

v_pk_name_csv := array_to_string(v_pk_name,',');

v_with_update := 'WITH a AS (SELECT '||v_pk_name_csv||' FROM '|| v_control ||' ORDER BY '||v_pk_name_csv||' LIMIT '|| v_limit ||') UPDATE '||v_control||' b SET processed = true FROM a WHERE a.'||v_pk_name[1]||' = b.'||v_pk_name[1];

v_pk_counter := 2;
IF array_length(v_pk_name, 1) > 1 THEN
    v_pk_where := '';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        v_pk_where := v_pk_where || ' AND a.'||v_pk_name[v_pk_counter]||' = b.'||v_pk_name[v_pk_counter];
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
END IF;

IF v_pk_where IS NOT NULL THEN
    v_with_update := v_with_update || v_pk_where;
END IF;
PERFORM gdb(p_debug, v_with_update);

v_pk_counter := 1;
WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
    IF v_pk_counter > 1 THEN
        v_pk_name_type_csv := v_pk_name_type_csv || ', ';
        v_pk_queue := v_pk_queue || ', ';
        v_pk_queue_where := v_pk_queue_where || ' OR ';
    END IF;
    v_pk_name_type_csv := v_pk_name_type_csv ||v_pk_name[v_pk_counter]||' '||v_pk_type[v_pk_counter];
    v_pk_queue := v_pk_queue || v_pk_name[v_pk_counter] || ' as mimeo_q_' || v_pk_name[v_pk_counter];
    v_pk_queue_where := v_pk_queue_where || v_pk_name[v_pk_counter] || ' = mimeo_q_' || v_pk_name[v_pk_counter];
    v_pk_counter := v_pk_counter + 1;
END LOOP;

v_trigger_update := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','|| quote_literal(v_with_update)||')';

-- Handles edge case to catch when a multi-column primary/unique key changes the value of a subset of the columns. 
v_remote_f_sql := 'SELECT '||v_cols||' 
    FROM '||v_source_table||', 
    (SELECT DISTINCT '||v_pk_queue||' FROM '||v_control||' WHERE processed = true and mimeo_source_deleted IS NULL) x ';
IF v_condition IS NOT NULL THEN
    v_remote_f_sql := v_remote_f_sql || ' ' || v_condition ||' AND ';
ELSE
    v_remote_f_sql := v_remote_f_sql || ' WHERE ';
END IF;
v_remote_f_sql := v_remote_f_sql || '(' || v_pk_queue_where || ')'; 

v_create_f_sql := 'CREATE TEMP TABLE '||v_tmp_table||'_full AS SELECT '||v_cols||' 
    FROM dblink('||quote_literal(v_dblink_name)||','||quote_literal(v_remote_f_sql)||') t ('||v_cols_n_types||')';

v_remote_d_sql = 'SELECT '||v_cols||', mimeo_source_deleted FROM '||v_control||' WHERE processed = true and mimeo_source_deleted IS NOT NULL';
v_create_d_sql = 'CREATE TEMP TABLE '||v_tmp_table||'_deleted AS SELECT '||v_cols||', mimeo_source_deleted
    FROM dblink('||quote_literal(v_dblink_name)||','||quote_literal(v_remote_d_sql)||') t ('||v_cols_n_types||', mimeo_source_deleted timestamptz)';

v_remote_q_sql := 'SELECT DISTINCT '||v_pk_name_csv||' FROM '||v_control||' WHERE processed = true and mimeo_source_deleted IS NULL';
v_create_q_sql := 'CREATE TEMP TABLE '||v_tmp_table||'_queue AS SELECT '||v_pk_name_csv||'
        FROM dblink('||quote_literal(v_dblink_name)||','||quote_literal(v_remote_q_sql)||') t ('||v_pk_name_type_csv||')';

v_delete_f_sql := 'DELETE FROM '||v_dest_table||' a USING '||v_tmp_table||'_queue b WHERE a.'||v_pk_name[1]||'= b.'||v_pk_name[1];
IF array_length(v_pk_name, 1) > 1 THEN
    v_delete_f_sql := v_delete_f_sql || v_pk_where;
END IF; 

-- remove rows that were deleted on source to ensure most recently deleted data is logged 
v_delete_d_sql := 'DELETE FROM '||v_dest_table||' a USING '||v_tmp_table||'_deleted b WHERE a.'||v_pk_name[1]||'= b.'||v_pk_name[1];
IF array_length(v_pk_name, 1) > 1 THEN
    v_delete_d_sql := v_delete_d_sql || v_pk_where;
END IF; 

v_insert_sql := 'INSERT INTO '||v_dest_table||'('||v_cols||') SELECT '||v_cols||' FROM '||v_tmp_table||'_full';
v_insert_deleted_sql := 'INSERT INTO '||v_dest_table||'('||v_cols||', mimeo_source_deleted) SELECT '||v_cols||', mimeo_source_deleted FROM '||v_tmp_table||'_deleted'; 

v_trigger_delete := 'SELECT dblink_exec('||quote_literal(v_dblink_name)||','||quote_literal('DELETE FROM '||v_control||' WHERE processed = true')||')'; 

PERFORM update_step(v_step_id, 'OK','Remote table is '||v_source_table);

PERFORM dblink_connect(v_dblink_name, auth(v_dblink));

-- update remote entries
v_step_id := add_step(v_job_id,'Updating remote trigger table');
PERFORM gdb(p_debug,v_trigger_update);
EXECUTE v_trigger_update INTO v_exec_status;    
PERFORM update_step(v_step_id, 'OK','Result was '||v_exec_status);

-- create temp table for insertion (inserts/updates)
v_step_id := add_step(v_job_id,'Create temp table from remote full table');
PERFORM gdb(p_debug,v_create_f_sql);
EXECUTE v_create_f_sql;  
GET DIAGNOSTICS v_full_rowcount = ROW_COUNT;
PERFORM gdb(p_debug,'Number of Insert/Update rows to process: '||v_full_rowcount);
PERFORM update_step(v_step_id, 'OK','Number of Insert/Update rows to process: '||v_full_rowcount);

-- create temp table for insertion (deleted rows)
v_step_id := add_step(v_job_id,'Create temp table from remote delete table');
PERFORM gdb(p_debug,v_create_d_sql);
EXECUTE v_create_d_sql;  
GET DIAGNOSTICS v_rowcount = ROW_COUNT;
PERFORM gdb(p_debug,'Number of Deleted rows to process '||v_rowcount);
PERFORM update_step(v_step_id, 'OK','Number of Deleted rows to process '||v_rowcount);
-- Check is here instead of earlier in case there are only deletes
v_step_id := add_step(v_job_id, 'Processing fetched rows');
IF v_rowcount < 1 AND v_full_rowcount < 1 THEN 
    PERFORM update_step(v_step_id, 'OK','No new rows found');
ELSE
    IF (v_full_rowcount + v_rowcount) < v_limit THEN
        PERFORM update_step(v_step_id, 'OK','Total number of rows to processes: '||v_full_rowcount + v_rowcount);
    ELSE
        PERFORM update_step(v_step_id, 'WARNING','Row count fetched equal to limit set: '||v_limit||'. Recommend increasing batch limit if possible.');
        v_batch_limit_reached := true;
    END IF;
    -- remove records from local table (inserts/updates)
    v_step_id := add_step(v_job_id,'Deleting insert/update records from local table');
    EXECUTE v_create_q_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Temp queue table row count '||v_rowcount::text);
    PERFORM gdb(p_debug,v_delete_f_sql);
    EXECUTE v_delete_f_sql; 
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Insert/Update rows removed from local table before applying changes: '||v_rowcount::text);
    PERFORM update_step(v_step_id, 'OK','Removed '||v_rowcount||' records');

    -- remove records from local table (deleted rows)
    v_step_id := add_step(v_job_id,'Deleting removed records from local table');
    PERFORM gdb(p_debug,v_delete_d_sql);
    EXECUTE v_delete_d_sql; 
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Deleted Rows removed from local table before applying changes: '||v_rowcount::text);
    PERFORM update_step(v_step_id, 'OK','Removed '||v_rowcount||' records');

    -- insert records to local table (inserts/updates)
    v_step_id := add_step(v_job_id,'Inserting new/updated records into local table');
    PERFORM gdb(p_debug,v_insert_sql);
    EXECUTE v_insert_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Rows inserted: '||v_rowcount::text);
    PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');

    -- insert records to local table (deleted rows to be kept)
    v_step_id := add_step(v_job_id,'Inserting deleted records into local table');
    PERFORM gdb(p_debug,v_insert_deleted_sql);
    EXECUTE v_insert_deleted_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM gdb(p_debug,'Rows inserted: '||v_rowcount::text);
    PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');

    -- clean out rows from txn table
    v_step_id := add_step(v_job_id,'Cleaning out rows from txn table');
    PERFORM gdb(p_debug,v_trigger_delete);
    EXECUTE v_trigger_delete INTO v_exec_status;
    PERFORM update_step(v_step_id, 'OK','Result was '||v_exec_status);
END IF;

-- update activity status
v_step_id := add_step(v_job_id,'Updating last_run in config table');
UPDATE refresh_config_logdel SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination; 
PERFORM update_step(v_step_id, 'OK','Last Value was '||current_timestamp);

PERFORM dblink_disconnect(v_dblink_name);

EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table||'_full';
EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table||'_deleted';

IF v_batch_limit_reached = false THEN
    PERFORM close_job(v_job_id);
ELSE
    -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
    -- Preventive warning to keep replication from falling behind.
    PERFORM fail_job(v_job_id, 2);
END IF;
-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_logdel'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF dblink_get_connections() @> ARRAY[v_dblink_name] THEN
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        PERFORM pg_advisory_unlock(hashtext('refresh_logdel'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;  
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF v_job_id IS NULL THEN
                v_job_id := add_job('Refresh Log Del: '||p_destination);
                v_step_id := add_step(v_job_id, 'EXCEPTION before job logging started');
        END IF;
        IF v_step_id IS NULL THEN
            v_step_id := add_step(v_job_id, 'EXCEPTION before first step logged');
        END IF;
        IF dblink_get_connections() @> ARRAY[v_dblink_name] THEN
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        PERFORM update_step(v_step_id, 'BAD', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        PERFORM fail_job(v_job_id);

        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

        PERFORM pg_advisory_unlock(hashtext('refresh_logdel'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;
END
$$;


/*
 *  Snap refresh to repull all table data
 */
CREATE OR REPLACE FUNCTION refresh_snap(p_destination text, p_index boolean DEFAULT true, p_debug boolean DEFAULT false, p_pulldata boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock          boolean; 
v_cols_n_types      text;
v_cols              text;
v_condition         text;
v_create_sql        text;
v_dblink            int;
v_dblink_name       text;
v_dblink_schema     text;
v_dest_table        text;
v_exists            int;
v_filter            text[];
v_insert_sql        text;
v_job_id            int;
v_jobmon_schema     text;
v_job_name          text;
v_lcols_array       text[];
v_local_sql         text;
v_l                 text;
v_match             boolean := 'f';
v_old_search_path   text;
v_parts             record;
v_post_script       text[];
v_rcols_array       text[];
v_refresh_snap      text;
v_remote_index_sql  text;
v_remote_sql        text;
v_row               record;
v_rowcount          bigint;
v_r                 text;
v_snap              text;
v_source_table      text;
v_step_id           int;
v_table_exists      int;
v_view_definition   text;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'notice', true );
END IF;

v_job_name := 'Refresh Snap: '||p_destination;
v_dblink_name := 'mimeo_snap_refresh_'||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||',public'',''false'')';

v_job_id := add_job(v_job_name);
PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);

-- Take advisory lock to prevent multiple calls to function overlapping and causing possible deadlock
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_snap'), hashtext(v_job_name));
IF v_adv_lock = 'false' THEN
    v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    PERFORM update_step(v_step_id, 'OK','Found concurrent job. Exiting gracefully');
    PERFORM close_job(v_job_id);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

v_step_id := add_step(v_job_id,'Grabbing Mapping, Building SQL');

SELECT source_table
    , dest_table
    , dblink
    , filter
    , condition
    , post_script 
INTO v_source_table
    , v_dest_table
    , v_dblink
    , v_filter
    , v_condition
    , v_post_script 
FROM refresh_config_snap
WHERE dest_table = p_destination; 
IF NOT FOUND THEN
   RAISE EXCEPTION 'ERROR: This table is not set up for snapshot replication: %',v_job_name; 
END IF;  

-- checking for current view

SELECT definition INTO v_view_definition FROM pg_views where
      ((schemaname || '.') || viewname)=v_dest_table;

v_exists := strpos(v_view_definition, 'snap1');
  IF v_exists > 0 THEN
    v_snap := '_snap2';
    ELSE
    v_snap := '_snap1';
 END IF;
v_refresh_snap := v_dest_table||v_snap;
PERFORM gdb(p_debug,'v_refresh_snap: '||v_refresh_snap::text);

PERFORM dblink_connect(v_dblink_name, @extschema@.auth(v_dblink));

v_remote_sql := 'SELECT array_to_string(array_agg(attname),'','') as cols, array_to_string(array_agg(attname||'' ''||format_type(atttypid, atttypmod)::text),'','') as cols_n_types FROM pg_attribute WHERE attrelid = '||quote_literal(v_source_table)||'::regclass AND attnum > 0 AND attisdropped is false';

-- Apply column filters if used
IF v_filter IS NOT NULL THEN
    v_remote_sql := v_remote_sql || ' AND ARRAY[attname::text] <@ '||quote_literal(v_filter);
END IF;

v_remote_sql := 'SELECT cols, cols_n_types FROM dblink('||quote_literal(v_dblink_name)||', ' || quote_literal(v_remote_sql) || ') t (cols text, cols_n_types text)';
perform gdb(p_debug,'v_remote_sql: '||v_remote_sql);
EXECUTE v_remote_sql INTO v_cols, v_cols_n_types;  
perform gdb(p_debug,'v_cols: '||v_cols);
perform gdb(p_debug,'v_cols_n_types: '||v_cols_n_types);

v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
-- Used by p_pull options in all maker functions to be able to create a replication job but pull no data
IF p_pulldata = false THEN
    v_remote_sql := v_remote_sql || ' LIMIT 0';
ELSIF v_condition IS NOT NULL THEN
    v_remote_sql := v_remote_sql || ' ' || v_condition;
END IF;

v_insert_sql := 'INSERT INTO ' || v_refresh_snap || ' SELECT '||v_cols||' FROM dblink('||quote_literal(v_dblink_name)||','||quote_literal(v_remote_sql)||') t ('||v_cols_n_types||')';

PERFORM update_step(v_step_id, 'OK','Done');

v_step_id := add_step(v_job_id,'Truncate non-active snap table');

-- Create snap table if it doesn't exist
SELECT string_to_array(v_refresh_snap, '.') AS oparts INTO v_parts;
SELECT INTO v_table_exists count(1) FROM pg_tables
    WHERE  schemaname = v_parts.oparts[1] AND
           tablename = v_parts.oparts[2];
IF v_table_exists = 0 THEN

    PERFORM gdb(p_debug,'Snap table does not exist. Creating... ');
    
    v_create_sql := 'CREATE TABLE ' || v_refresh_snap || ' (' || v_cols_n_types || ')';
    perform gdb(p_debug,'v_create_sql: '||v_create_sql::text);
    EXECUTE v_create_sql;
ELSE 

/* Check local column definitions against remote and recreate table if different. Allows automatic recreation of
        snap tables if columns change (add, drop type change)  */  
    v_local_sql := 'SELECT array_agg(attname||'' ''||format_type(atttypid, atttypmod)::text) as cols_n_types FROM pg_attribute WHERE attnum > 0 AND attisdropped is false AND attrelid = ' || quote_literal(v_refresh_snap) || '::regclass'; 
        
    PERFORM gdb(p_debug,'v_local_sql: '||v_local_sql::text);

    EXECUTE v_local_sql INTO v_lcols_array;
    SELECT string_to_array(v_cols_n_types, ',') AS cols INTO v_rcols_array;

    -- Check to see if there's a change in the column structure on the remote
    FOREACH v_r IN ARRAY v_rcols_array LOOP
        v_match := 'f';
        FOREACH v_l IN ARRAY v_lcols_array LOOP
            IF v_r = v_l THEN
                v_match := 't';
                EXIT;
            END IF;
        END LOOP;
    END LOOP;

    IF v_match = 'f' THEN
        EXECUTE 'DROP TABLE ' || v_refresh_snap;
        EXECUTE 'DROP VIEW ' || v_dest_table;
        v_create_sql := 'CREATE TABLE ' || v_refresh_snap || ' (' || v_cols_n_types || ')';
        PERFORM gdb(p_debug,'v_create_sql: '||v_create_sql::text);
        EXECUTE v_create_sql;
        v_step_id := add_step(v_job_id,'Source table structure changed.');
        PERFORM update_step(v_step_id, 'OK','Tables and view dropped and recreated. Please double-check snap table attributes (permissions, indexes, etc');
        PERFORM gdb(p_debug,'Source table structure changed. Tables and view dropped and recreated. Please double-check snap table attributes (permissions, indexes, etc)');

    END IF;
    -- truncate non-active snap table
    EXECUTE 'TRUNCATE TABLE ' || v_refresh_snap;

    PERFORM update_step(v_step_id, 'OK','Done');
END IF;

-- populating snap table
v_step_id := add_step(v_job_id,'Inserting records into local table');
PERFORM gdb(p_debug,'Inserting rows... '||v_insert_sql);
EXECUTE v_insert_sql; 
GET DIAGNOSTICS v_rowcount = ROW_COUNT;
PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');

-- Create indexes if new table was created
IF (v_table_exists = 0 OR v_match = 'f') AND p_index = true THEN
    v_remote_index_sql := 'SELECT 
        CASE
            WHEN i.indisprimary IS true THEN ''primary''
            WHEN i.indisunique IS true THEN ''unique''
            ELSE ''index''
        END AS key_type,
        ( SELECT array_agg( a.attname ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid ';
    IF v_filter IS NOT NULL THEN
        v_remote_index_sql := v_remote_index_sql || ' WHERE ARRAY[a.attname::text] <@ '||quote_literal(v_filter);
    END IF;
    v_remote_index_sql := v_remote_index_sql || ') AS indkey_names
        FROM pg_index i
        WHERE i.indrelid = '||quote_literal(v_source_table)||'::regclass';

    FOR v_row IN EXECUTE 'SELECT key_type, indkey_names FROM dblink('||quote_literal(v_dblink_name)||', '||quote_literal(v_remote_index_sql)||') t (key_type text, indkey_names text[])' LOOP
        IF v_row.indkey_names IS NOT NULL THEN   -- If column filter is used, indkey_name column may be null
            IF v_row.key_type = 'primary' THEN
                RAISE NOTICE 'Creating primary key...';
                EXECUTE 'ALTER TABLE '||v_refresh_snap||' ADD CONSTRAINT '||v_parts.oparts[2]||'_'||array_to_string(v_row.indkey_names, '_')||'_idx PRIMARY KEY ('||array_to_string(v_row.indkey_names, ',')||')';
            ELSIF v_row.key_type = 'unique' THEN
                RAISE NOTICE 'Creating unique index...';
                EXECUTE 'CREATE UNIQUE INDEX '||v_parts.oparts[2]||'_'||array_to_string(v_row.indkey_names, '_')||'_idx ON '||v_refresh_snap|| '('||array_to_string(v_row.indkey_names, ',')||')';
            ELSE
                RAISE NOTICE 'Creating index...';
                EXECUTE 'CREATE INDEX '||v_parts.oparts[2]||'_'||array_to_string(v_row.indkey_names, '_')||'_idx ON '||v_refresh_snap|| '('||array_to_string(v_row.indkey_names, ',')||')';
            END IF;
        END IF;
    END LOOP;
END IF;

IF v_rowcount IS NOT NULL THEN
     EXECUTE 'ANALYZE ' ||v_refresh_snap;

    --SET statement_timeout='30 min';  
    
    -- swap view
    v_step_id := add_step(v_job_id,'Swap view to '||v_refresh_snap);
    PERFORM gdb(p_debug,'Swapping view to '||v_refresh_snap);
    EXECUTE 'CREATE OR REPLACE VIEW '||v_dest_table||' AS SELECT * FROM '||v_refresh_snap;
    PERFORM update_step(v_step_id, 'OK','View Swapped');

    v_step_id := add_step(v_job_id,'Updating last value');
    UPDATE refresh_config_snap set last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
    PERFORM update_step(v_step_id, 'OK','Done');

    -- Runs special sql to fix indexes, permissions, etc on recreated objects
    IF v_match = 'f' AND v_post_script IS NOT NULL THEN
        v_step_id := add_step(v_job_id,'Applying post_script sql commands due to schema change');
        PERFORM @extschema@.post_script(v_dest_table);
        PERFORM update_step(v_step_id, 'OK','Done');
    END IF;

    PERFORM close_job(v_job_id);
ELSE
    RAISE EXCEPTION 'No rows found in source table';
END IF;

PERFORM dblink_disconnect(v_dblink_name);

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_snap'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF dblink_get_connections() @> ARRAY[v_dblink_name] THEN
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        PERFORM pg_advisory_unlock(hashtext('refresh_snap'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;   
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF v_job_id IS NULL THEN
            v_job_id := add_job('Refresh Snap: '||p_destination);
            v_step_id := add_step(v_job_id, 'EXCEPTION before job logging started');
        END IF;
        IF v_step_id IS NULL THEN
            v_step_id := add_step(v_job_id, 'EXCEPTION before first step logged');
        END IF;
        PERFORM update_step(v_step_id, 'BAD', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        PERFORM fail_job(v_job_id);
        IF dblink_get_connections() @> ARRAY[v_dblink_name] THEN
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        PERFORM pg_advisory_unlock(hashtext('refresh_snap'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;
END
$$;


/*
 *  Refresh insert/update only table based on timestamp control field
 */
CREATE OR REPLACE FUNCTION refresh_updater(p_destination text, p_limit integer DEFAULT NULL, p_repull boolean DEFAULT false, p_repull_start text DEFAULT NULL, p_repull_end text DEFAULT NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_adv_lock              boolean;
v_batch_limit_reached   boolean := false;
v_boundary_sql          text;
v_boundary              timestamptz;
v_cols_n_types          text;
v_cols                  text;
v_condition             text;
v_control               text;
v_create_sql            text;
v_dblink_schema         text;
v_dblink                int;
v_delete_sql            text;
v_dest_table            text;
v_dst_active            boolean;
v_dst_check             boolean;
v_dst_start             int;
v_dst_end               int;
v_field                 text;
v_filter                text[];
v_full_refresh          boolean := false;
v_insert_sql            text;
v_job_id                int;
v_jobmon_schema         text;
v_job_name              text;
v_last_value_sql        text; 
v_last_value            timestamptz;
v_limit                 int;
v_now                   timestamptz := now(); 
v_old_search_path       text;
v_pk_counter            int := 2;
v_pk_name               text[];
v_pk_type               text[];
v_pk_where              text;
v_remote_boundry_sql    text;
v_remote_boundry        timestamptz;
v_remote_sql            text;
v_rowcount              bigint; 
v_source_table          text;
v_step_id               int;
v_tmp_table             text;

BEGIN

IF p_debug IS DISTINCT FROM true THEN
    PERFORM set_config( 'client_min_messages', 'warning', true );
END IF;

v_job_name := 'Refresh Updater: '||p_destination;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions, especially job logging
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||',public'',''false'')';


v_job_id := add_job(v_job_name);
PERFORM gdb(p_debug,'Job ID: '||v_job_id::text);

-- Take advisory lock to prevent multiple calls to function overlapping
v_adv_lock := pg_try_advisory_lock(hashtext('refresh_updater'), hashtext(v_job_name));
IF v_adv_lock = 'false' THEN
    v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
    PERFORM gdb(p_debug,'Obtaining advisory lock FAILED for job: '||v_job_name);
    PERFORM update_step(v_step_id, 'OK','Found concurrent job. Exiting gracefully');
    PERFORM close_job(v_job_id);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    RETURN;
END IF;

-- grab boundry
SELECT source_table
    , dest_table
    , 'tmp_'||replace(dest_table,'.','_')
    , dblink
    , control
    , last_value
    , now() - boundary::interval
    , pk_name
    , pk_type
    , filter
    , condition
    , dst_active
    , dst_start
    , dst_end
    , batch_limit  
FROM refresh_config_updater
WHERE dest_table = p_destination INTO 
    v_source_table
    , v_dest_table
    , v_tmp_table
    , v_dblink
    , v_control
    , v_last_value
    , v_boundary
    , v_pk_name
    , v_pk_type
    , v_filter
    , v_condition
    , v_dst_active
    , v_dst_start
    , v_dst_end
    , v_limit;
IF NOT FOUND THEN
   RAISE EXCEPTION 'ERROR: no configuration found for %',v_job_name;
END IF;

-- Do not allow this function to run during DST time change if config option is true. Otherwise will miss data from source
IF v_dst_active THEN
    v_dst_check := @extschema@.dst_change(v_now);
    IF v_dst_check THEN 
        IF to_number(to_char(v_now, 'HH24MM'), '0000') > v_dst_start AND to_number(to_char(v_now, 'HH24MM'), '0000') < v_dst_end THEN
            v_step_id := add_step( v_job_id, 'DST Check');
            PERFORM update_step(v_step_id, 'OK', 'Job CANCELLED - Does not run during DST time change');
            UPDATE refresh_config_updater SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
            PERFORM close_job(v_job_id);
            PERFORM gdb(p_debug, 'Cannot run during DST time change');
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
            RETURN;
        END IF;
    END IF;
END IF;

v_step_id := add_step(v_job_id,'Building SQL');

-- determine column list, column type list
IF v_filter IS NULL THEN 
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',')
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND attnum > 0 AND attisdropped is false;
ELSE
    -- ensure all primary key columns are included in any column filters
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(v_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary/unique key for %',v_job_name; 
        END IF;
    END LOOP;
    SELECT array_to_string(array_agg(attname),','), array_to_string(array_agg(attname||' '||format_type(atttypid, atttypmod)::text),',') 
        INTO v_cols, v_cols_n_types
        FROM pg_attribute WHERE attrelid = p_destination::regclass AND ARRAY[attname::text] <@ v_filter AND attnum > 0 AND attisdropped is false;
END IF;    

v_last_value_sql := 'SELECT max('||v_control||') FROM '||v_tmp_table;
v_limit = COALESCE(p_limit, v_limit, 10000);

-- Repull old data instead of normal new data pull
IF p_repull THEN
    -- Repull ALL data if no start and end values set
    IF p_repull_start IS NULL AND p_repull_end IS NULL THEN
        -- Actual truncate is done after pull to temp table to minimize lock on dest_table
        PERFORM update_step(v_step_id, 'OK','Request to repull ALL data from source. This could take a while...');
        v_full_refresh := true;
        v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition;
        END IF;
    ELSE
        PERFORM update_step(v_step_id, 'OK','Request to repull data from '||p_repull_start||' to '||p_repull_end);
        PERFORM gdb(p_debug,'Request to repull data from '||p_repull_start||' to '||p_repull_end);
        v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
        IF v_condition IS NOT NULL THEN
            v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
        ELSE
            v_remote_sql := v_remote_sql || ' WHERE ';
        END IF;
        v_remote_sql := v_remote_sql ||v_control||' > '||quote_literal(COALESCE(p_repull_start, '-infinity'))||' AND '
            ||v_control||' < '||quote_literal(COALESCE(p_repull_end, 'infinity'));
        -- Delete the old local data. Unlike inserter, just do this in the normal delete step below
        v_delete_sql := 'DELETE FROM '||v_dest_table||' WHERE '||v_control||' > '||quote_literal(COALESCE(p_repull_start, '-infinity'))||' AND '
            ||v_control||' < '||quote_literal(COALESCE(p_repull_end, 'infinity'));
        -- Set last_value equal to local, real table max instead of temp table (just in case)
        v_last_value_sql := 'SELECT max('||v_control||') FROM '||v_dest_table;
    END IF;
ELSE
    -- does < for upper boundary to keep missing data from happening on rare edge case where a newly inserted row outside the transaction batch
    -- has the exact same timestamp as the previous batch's max timestamp
    v_remote_sql := 'SELECT '||v_cols||' FROM '||v_source_table;
    IF v_condition IS NOT NULL THEN
        v_remote_sql := v_remote_sql || ' ' || v_condition || ' AND ';
    ELSE
        v_remote_sql := v_remote_sql || ' WHERE ';
    END IF;
    v_remote_sql := v_remote_sql ||v_control||' > '||quote_literal(v_last_value)||' AND '||v_control||' < '||quote_literal(v_boundary)||' ORDER BY '||v_control||' ASC LIMIT '|| v_limit;

    v_delete_sql := 'DELETE FROM '||v_dest_table||' USING '||v_tmp_table||' t WHERE '||v_dest_table||'.'||v_pk_name[1]||'=t.'||v_pk_name[1]; 

    PERFORM update_step(v_step_id, 'OK','Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);
    PERFORM gdb(p_debug,'Grabbing rows from '||v_last_value::text||' to '||v_boundary::text);
END IF;

v_create_sql := 'CREATE TEMP TABLE '||v_tmp_table||' AS SELECT '||v_cols||' FROM dblink(auth('||v_dblink||'),'||quote_literal(v_remote_sql)||') t ('||v_cols_n_types||')';

IF array_length(v_pk_name, 1) > 1 THEN
    v_pk_where := '';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        v_pk_where := v_pk_where || ' AND '||v_dest_table||'.'||v_pk_name[v_pk_counter]||' = t.'||v_pk_name[v_pk_counter];
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
END IF;

IF v_pk_where IS NOT NULL THEN
    v_delete_sql := v_delete_sql || v_pk_where;
END IF; 

v_insert_sql := 'INSERT INTO '||v_dest_table||'('||v_cols||') SELECT '||v_cols||' FROM '||v_tmp_table; 

-- create temp from remote
v_step_id := add_step(v_job_id,'Creating temp table ('||v_tmp_table||') from remote table');
    PERFORM gdb(p_debug,v_create_sql);
    EXECUTE v_create_sql;     
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    IF v_rowcount < 1 THEN 
        PERFORM update_step(v_step_id, 'OK','No new rows found');
        EXECUTE 'DROP TABLE IF EXISTS ' || v_tmp_table;
        UPDATE refresh_config_updater SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
        PERFORM close_job(v_job_id);
        PERFORM gdb(p_debug, 'No new rows found');
        -- Ensure old search path is reset for the current session
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
        RETURN;
    -- Not recommended that the batch actually equal the limit set if possible.
    ELSIF v_rowcount = v_limit THEN
        PERFORM update_step(v_step_id, 'WARNING','Row count fetched equal to limit set: '||v_limit||'. Recommend increasing batch limit if possible.');
        PERFORM gdb(p_debug, 'Row count fetched equal to limit set: '||v_limit||'. Recommend increasing batch limit if possible.'); 
        EXECUTE v_last_value_sql INTO v_last_value;
        v_step_id := add_step(v_job_id, 'Removing high boundary rows from this batch to avoid missing data');       
        EXECUTE 'DELETE FROM '||v_tmp_table||' WHERE '||v_control||' = '||quote_literal(v_last_value);
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        PERFORM update_step(v_step_id, 'OK', 'Removed '||v_rowcount||' rows. Batch now contains '||v_limit - v_rowcount||' records');
        PERFORM gdb(p_debug, 'Removed '||v_rowcount||' rows from batch. Batch table now contains '||v_limit - v_rowcount||' records');
        v_batch_limit_reached := true;
        IF (v_limit - v_rowcount) < 1 THEN
            v_step_id := add_step(v_job_id, 'Reached inconsistent state');
            PERFORM update_step(v_step_id, 'CRITICAL', 'Batch contained max rows ('||v_limit||') and all contained the same timestamp value. Unable to guarentee rows will ever be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            PERFORM gdb(p_debug, 'Batch contained max rows desired ('||v_limit||') and all contained the same timestamp value. Unable to guarentee rows will be replicated consistently. Increase row limit parameter to allow a consistent batch.');
            UPDATE refresh_config_updater SET last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
            PERFORM fail_job(v_job_id);
            EXECUTE 'DROP TABLE IF EXISTS ' || v_tmp_table;
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
            RETURN;
        END IF;
    ELSE
        PERFORM update_step(v_step_id, 'OK','Batch contains '||v_rowcount||' records');
        PERFORM gdb(p_debug, 'Batch contains '||v_rowcount||' records');
    END IF;

IF v_full_refresh THEN        
        EXECUTE 'TRUNCATE '||v_dest_table;
ELSE
    -- delete records to be updated. This step not needed during full refresh
    v_step_id := add_step(v_job_id,'Deleting records marked for update in local table');
    perform gdb(p_debug,v_delete_sql);
    execute v_delete_sql; 
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    PERFORM update_step(v_step_id, 'OK','Deleted '||v_rowcount||' records');
END IF;

-- insert
v_step_id := add_step(v_job_id,'Inserting new records into local table');
perform gdb(p_debug,v_insert_sql);
execute v_insert_sql; 
GET DIAGNOSTICS v_rowcount = ROW_COUNT;
PERFORM update_step(v_step_id, 'OK','Inserted '||v_rowcount||' records');

-- Get new last_value
v_step_id := add_step(v_job_id, 'Getting local max control field value for next lower boundary');
PERFORM gdb(p_debug, v_last_value_sql);
EXECUTE v_last_value_sql INTO v_last_value;
PERFORM update_step(v_step_id, 'OK','Max value is: '||v_last_value);
PERFORM gdb(p_debug, 'Max value is: '||v_last_value);

-- update boundries
v_step_id := add_step(v_job_id,'Updating last_value in config');
UPDATE refresh_config_updater set last_value = v_last_value, last_run = CURRENT_TIMESTAMP WHERE dest_table = p_destination;  
PERFORM update_step(v_step_id, 'OK','Done');

EXECUTE 'DROP TABLE IF EXISTS '||v_tmp_table;

IF v_batch_limit_reached = false THEN
    PERFORM close_job(v_job_id);
ELSE
    -- Set final job status to level 2 (WARNING) to bring notice that the batch limit was reached and may need adjusting.
    -- Preventive warning to keep replication from falling behind.
    PERFORM fail_job(v_job_id, 2);
END IF;

-- Ensure old search path is reset for the current session
EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));

EXCEPTION
    WHEN QUERY_CANCELED THEN
        PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;  
    WHEN OTHERS THEN
        -- Exception block resets path, so have to reset it again
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||','||v_dblink_schema||''',''false'')';
        IF v_job_id IS NULL THEN
                v_job_id := add_job('Refresh Updater: '||p_destination);
                v_step_id := add_step(v_job_id, 'EXCEPTION before job logging started');
        END IF;
        IF v_step_id IS NULL THEN
            v_step_id := add_step(v_job_id, 'EXCEPTION before first step logged');
        END IF;
        PERFORM update_step(v_step_id, 'BAD', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        PERFORM fail_job(v_job_id);

        -- Ensure old search path is reset for the current session
       EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

        PERFORM pg_advisory_unlock(hashtext('refresh_updater'), hashtext(v_job_name));
        RAISE EXCEPTION '%', SQLERRM;
END
$$;


/*
 *  DML maker function.
 */
CREATE OR REPLACE FUNCTION dml_maker(
    p_src_table text
    , p_dblink_id int
    , p_dest_table text DEFAULT NULL
    , p_index boolean DEFAULT true
    , p_filter text[] DEFAULT NULL
    , p_condition text DEFAULT NULL
    , p_pulldata boolean DEFAULT true
    , p_pk_name text[] DEFAULT NULL
    , p_pk_type text[] DEFAULT NULL) 
RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

v_create_trig               text;
v_data_source               text;
v_dblink_schema             text;
v_dest_check                text;
v_dest_schema_name          text;
v_dest_table_name           text;
v_exists                    int := 0;
v_field                     text;
v_insert_refresh_config     text;
v_key_type                  text;
v_old_search_path           text;
v_pk_counter                int := 1;
v_pk_name                   text[] := p_pk_name;
v_pk_name_n_type            text[];
v_pk_type                   text[] := p_pk_type;
v_remote_exists             int := 0;
v_remote_key_sql            text;
v_remote_q_index            text;
v_remote_q_table            text;
v_src_table_name            text;
v_trigger_func              text;

BEGIN

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||',public'',''false'')';

IF (p_pk_name IS NULL AND p_pk_type IS NOT NULL) OR (p_pk_name IS NOT NULL AND p_pk_type IS NULL) THEN
    RAISE EXCEPTION 'Cannot manually set primary/unique key field(s) without defining type(s) or vice versa';
END IF;

SELECT data_source INTO v_data_source FROM @extschema@.dblink_mapping WHERE data_source_id = p_dblink_id; 
IF NOT FOUND THEN
	RAISE EXCEPTION 'ERROR: database link ID is incorrect %', p_dblink_id; 
END IF;

IF p_dest_table IS NULL THEN
    p_dest_table := p_src_table;
END IF;

v_src_table_name := replace(p_src_table, '.', '_');

IF position('.' in p_dest_table) > 0 THEN
    v_dest_schema_name := split_part(p_dest_table, '.', 1); 
    v_dest_table_name := split_part(p_dest_table, '.', 2);
END IF;

PERFORM dblink_connect('mimeo_dml', @extschema@.auth(p_dblink_id));

IF p_pk_name IS NULL AND p_pk_type IS NULL THEN
    -- Either gets the primary key or it gets the first unique index in alphabetical order by index name. 
    v_remote_key_sql := 'SELECT 
        CASE
            WHEN i.indisprimary IS true THEN ''primary''
            WHEN i.indisunique IS true THEN ''unique''
        END AS key_type,
        ( SELECT array_agg( a.attname ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid
            WHERE a.attnotnull
        ) AS indkey_names,
        ( SELECT array_agg( a.atttypid::regtype::text ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid
            WHERE a.attnotnull 
        ) AS indkey_types
        FROM pg_index i
        WHERE i.indrelid = '||quote_literal(p_src_table)||'::regclass
            AND (i.indisprimary OR i.indisunique)
        ORDER BY key_type LIMIT 1';

    EXECUTE 'SELECT key_type, indkey_names, indkey_types FROM dblink(''mimeo_dml'', '||quote_literal(v_remote_key_sql)||') t (key_type text, indkey_names text[], indkey_types text[])' 
        INTO v_key_type, v_pk_name, v_pk_type;
END IF;

RAISE NOTICE 'v_key_type: %', v_key_type;
RAISE NOTICE 'v_pk_name: %', v_pk_name;
RAISE NOTICE 'v_pk_type: %', v_pk_type;

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'Source table has no valid primary key or unique index';
END IF;

IF p_filter IS NOT NULL THEN
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(p_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary/unique key for source table %',p_src_table; 
        END IF;
    END LOOP;
END IF;

v_remote_q_table := 'CREATE TABLE @extschema@.'||v_src_table_name||'_pgq (';
WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
    v_remote_q_table := v_remote_q_table || v_pk_name[v_pk_counter]||' '||v_pk_type[v_pk_counter];
    v_pk_counter := v_pk_counter + 1;
    IF v_pk_counter <= array_length(v_pk_name,1) THEN
        v_remote_q_table := v_remote_q_table || ', ';
    END IF;
END LOOP;
v_remote_q_table := v_remote_q_table || ', processed boolean)';

RAISE NOTICE 'v_remote_q_table: %', v_remote_q_table;

v_remote_q_index := 'CREATE INDEX '||v_src_table_name||'_pgq_'||array_to_string(v_pk_name, '_')||'_idx ON @extschema@.'||v_src_table_name||'_pgq ('||array_to_string(v_pk_name, ',')||')';

v_pk_counter := 1;
v_trigger_func := 'CREATE FUNCTION @extschema@.'||v_src_table_name||'_mimeo_queue() RETURNS trigger LANGUAGE plpgsql AS $_$ DECLARE ';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        v_trigger_func := v_trigger_func||'v_'||v_pk_name[v_pk_counter]||' '||v_pk_type[v_pk_counter]||'; ';
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
    v_pk_counter := 1;
    v_trigger_func := v_trigger_func || ' BEGIN IF TG_OP = ''INSERT'' THEN ';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||v_pk_name[v_pk_counter]||' := NEW.'||v_pk_name[v_pk_counter]||'; ';
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
    v_pk_counter := 1;
    v_trigger_func := v_trigger_func || ' ELSE ';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||v_pk_name[v_pk_counter]||' := OLD.'||v_pk_name[v_pk_counter]||'; ';
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
    v_pk_counter := 1;
    v_trigger_func := v_trigger_func || ' END IF; INSERT INTO @extschema@.'||v_src_table_name||'_pgq ('||array_to_string(v_pk_name, ',')||') ';
    v_trigger_func := v_trigger_func || ' VALUES (';
    WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
        IF v_pk_counter > 1 THEN
            v_trigger_func := v_trigger_func || ', ';
        END IF;
        v_trigger_func := v_trigger_func||'v_'||v_pk_name[v_pk_counter];
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func || '); RETURN NULL; END $_$;';

v_create_trig := 'CREATE TRIGGER '||v_src_table_name||'_mimeo_trig AFTER INSERT OR DELETE OR UPDATE';
IF p_filter IS NOT NULL THEN
    v_create_trig := v_create_trig || ' OF '||array_to_string(p_filter, ',');
END IF;
v_create_trig := v_create_trig || ' ON '||p_src_table||' FOR EACH ROW EXECUTE PROCEDURE @extschema@.'||v_src_table_name||'_mimeo_queue()';

RAISE NOTICE 'Creating objects on source database (function, trigger & queue table)...';

PERFORM dblink_exec('mimeo_dml', v_remote_q_table);
PERFORM dblink_exec('mimeo_dml', v_remote_q_index);
PERFORM dblink_exec('mimeo_dml', v_trigger_func);
PERFORM dblink_exec('mimeo_dml', v_create_trig);

-- Only create destination table if it doesn't already exist
SELECT schemaname||'.'||tablename INTO v_dest_check FROM pg_tables WHERE schemaname = v_dest_schema_name AND tablename = v_dest_table_name;
IF v_dest_check IS NULL THEN
    RAISE NOTICE 'Snapshotting source table to pull all current source data...';
    -- Snapshot the table after triggers have been created to ensure all new data after setup is replicated
    v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_snap(source_table, dest_table, dblink, filter, condition) VALUES('
        ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||','
        ||COALESCE(quote_literal(p_filter), 'NULL')||','||COALESCE(quote_literal(p_condition), 'NULL')||')';
    EXECUTE v_insert_refresh_config;

    EXECUTE 'SELECT @extschema@.refresh_snap('||quote_literal(p_dest_table)||', p_index := '||p_index||', p_pulldata := '||p_pulldata||')';
    PERFORM @extschema@.snapshot_destroyer(p_dest_table, 'ARCHIVE');
    -- Ensure destination indexes that are needed for efficient replication are created even if p_index is set false
    IF p_index = false THEN
        RAISE NOTICE 'Adding primary/unique key to table...';
        IF v_key_type = 'primary' THEN
            EXECUTE 'ALTER TABLE '||p_dest_table||' ADD PRIMARY KEY('||array_to_string(v_pk_name, ',')||')';
        ELSE
            EXECUTE 'CREATE UNIQUE INDEX ON '||p_dest_table||' ('||array_to_string(v_pk_name, ',')||')';
        END IF;    
    END IF;
ELSE
    RAISE NOTICE 'Destination table % already exists. No data or indexes were pulled from source', p_dest_table;
END IF;

v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_dml(source_table, dest_table, dblink, control, pk_name, pk_type, last_run, filter, condition) VALUES('
    ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||', '||quote_literal('@extschema@.'||v_src_table_name||'_pgq')||', '
    ||quote_literal(v_pk_name)||', '||quote_literal(v_pk_type)||', '||quote_literal(CURRENT_TIMESTAMP)||','||COALESCE(quote_literal(p_filter), 'NULL')||','
    ||COALESCE(quote_literal(p_condition), 'NULL')||')';
RAISE NOTICE 'Inserting data into config table';
EXECUTE v_insert_refresh_config;

PERFORM dblink_disconnect('mimeo_dml');

EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

RAISE NOTICE 'Done';

EXCEPTION
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||''',''false'')';
        -- Only cleanup remote objects if replication doesn't exist at all for source table
        EXECUTE 'SELECT count(*) FROM @extschema@.refresh_config_dml WHERE source_table = '||quote_literal(p_src_table) INTO v_exists;
        IF v_exists = 0 THEN
            PERFORM dblink_exec('mimeo_dml', 'DROP TABLE IF EXISTS @extschema@.'||v_src_table_name||'_pgq');
            PERFORM dblink_exec('mimeo_dml', 'DROP TRIGGER IF EXISTS '||v_src_table_name||'_mimeo_trig ON '||p_src_table);
            PERFORM dblink_exec('mimeo_dml', 'DROP FUNCTION IF EXISTS @extschema@.'||v_src_table_name||'_mimeo_queue()');
        END IF;
        IF dblink_get_connections() @> '{mimeo_dml}' THEN
            PERFORM dblink_disconnect('mimeo_dml');
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        IF v_exists = 0 THEN
            RAISE EXCEPTION 'dml_maker() failure. No mimeo configuration found for source %. Cleaned up source table mimeo objects (queue table, function & trigger) if they existed.  SQLERRM: %', p_src_table, SQLERRM;
        ELSE
            RAISE EXCEPTION 'dml_maker() failure. Check to see if dml configuration for % already exists. SQLERRM: % ', p_src_table, SQLERRM;
        END IF;
END
$$;


/*
 *  Logdel maker function.
 */
CREATE OR REPLACE FUNCTION logdel_maker(
    p_src_table text
    , p_dblink_id int
    , p_dest_table text DEFAULT NULL
    , p_index boolean DEFAULT true
    , p_filter text[] DEFAULT NULL
    , p_condition text DEFAULT NULL
    , p_pulldata boolean DEFAULT true
    , p_pk_name text[] DEFAULT NULL
    , p_pk_type text[] DEFAULT NULL) 
RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

v_col_exists                int;
v_cols                      text[];
v_cols_csv                  text;
v_cols_n_types              text[];
v_cols_n_types_csv          text;
v_counter                   int := 1;
v_create_trig               text;
v_data_source               text;
v_dblink_schema             text;
v_dest_check                text;
v_dest_schema_name          text;
v_dest_table_name           text;
v_exists                    int := 0;
v_field                     text;
v_insert_refresh_config     text;
v_key_type                  text;
v_old_search_path           text;
v_pk_name                   text[] := p_pk_name;
v_pk_type                   text[] := p_pk_type;
v_remote_key_sql            text;
v_remote_sql                text;
v_remote_q_index            text;
v_remote_q_table            text;
v_src_table_name            text;
v_trigger_func              text;
v_types                     text[];

BEGIN

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||',public'',''false'')';

IF (p_pk_name IS NULL AND p_pk_type IS NOT NULL) OR (p_pk_name IS NOT NULL AND p_pk_type IS NULL) THEN
    RAISE EXCEPTION 'Cannot manually set primary/unique key field(s) without defining type(s) or vice versa';
END IF;

SELECT data_source INTO v_data_source FROM @extschema@.dblink_mapping WHERE data_source_id = p_dblink_id; 
IF NOT FOUND THEN
	RAISE EXCEPTION 'ERROR: database link ID is incorrect %', p_dblink_id; 
END IF;

IF p_dest_table IS NULL THEN
    p_dest_table := p_src_table;
END IF;

v_src_table_name := replace(p_src_table, '.', '_');

IF position('.' in p_dest_table) > 0 THEN
    v_dest_schema_name := split_part(p_dest_table, '.', 1); 
    v_dest_table_name := split_part(p_dest_table, '.', 2);
END IF;

PERFORM dblink_connect('mimeo_logdel', @extschema@.auth(p_dblink_id));

v_remote_sql := 'SELECT array_agg(attname) as cols, array_agg(format_type(atttypid, atttypmod)::text) as types, array_agg(attname||'' ''||format_type(atttypid, atttypmod)::text) as cols_n_types FROM pg_attribute WHERE attrelid = ' || quote_literal(p_src_table) || '::regclass AND attnum > 0 AND attisdropped is false';
-- Apply column filters if used
IF p_filter IS NOT NULL THEN
    v_remote_sql := v_remote_sql || ' AND ARRAY[attname::text] <@ '||quote_literal(p_filter);
END IF;
v_remote_sql := 'SELECT cols, types, cols_n_types FROM dblink(''mimeo_logdel'', ' || quote_literal(v_remote_sql) || ') t (cols text[], types text[], cols_n_types text[])';
EXECUTE v_remote_sql INTO v_cols, v_types, v_cols_n_types;

v_cols_csv := array_to_string(v_cols, ',');
v_cols_n_types_csv := array_to_string(v_cols_n_types, ',');

v_remote_q_table := 'CREATE TABLE @extschema@.'||v_src_table_name||'_pgq ('||v_cols_n_types_csv||', mimeo_source_deleted timestamptz, processed boolean)';

IF p_pk_name IS NULL AND p_pk_type IS NULL THEN
    -- Either gets the primary key or it gets the first unique index in alphabetical order by index name
    v_remote_key_sql := 'SELECT 
        CASE
            WHEN i.indisprimary IS true THEN ''primary''
            WHEN i.indisunique IS true THEN ''unique''
        END AS key_type,
        ( SELECT array_agg( a.attname ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid
            WHERE a.attnotnull
        ) AS indkey_names,
        ( SELECT array_agg( a.atttypid::regtype::text ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid
            WHERE a.attnotnull 
        ) AS indkey_types
        FROM pg_index i
        WHERE i.indrelid = '||quote_literal(p_src_table)||'::regclass
            AND (i.indisprimary OR i.indisunique)
        ORDER BY key_type LIMIT 1';

    EXECUTE 'SELECT key_type, indkey_names, indkey_types FROM dblink(''mimeo_logdel'', '||quote_literal(v_remote_key_sql)||') t (key_type text, indkey_names text[], indkey_types text[])' 
        INTO v_key_type, v_pk_name, v_pk_type;
END IF;

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'Source table has no valid primary key or unique index';
END IF;

IF p_filter IS NOT NULL THEN
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(p_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary/unique key for source table %', p_src_table;
        END IF;
    END LOOP;
END IF;

v_remote_q_index := 'CREATE INDEX '||v_src_table_name||'_pgq_'||array_to_string(v_pk_name, '_')||'_idx ON @extschema@.'||v_src_table_name||'_pgq ('||array_to_string(v_pk_name, ',')||')';

v_counter := 1;
v_trigger_func := 'CREATE FUNCTION @extschema@.'||v_src_table_name||'_mimeo_queue() RETURNS trigger LANGUAGE plpgsql AS $_$ DECLARE ';
    WHILE v_counter <= array_length(v_cols,1) LOOP
        v_trigger_func := v_trigger_func||'v_'||v_cols[v_counter]||' '||v_types[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func || 'v_del_time timestamptz; ';
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' BEGIN 
        IF TG_OP = ''INSERT'' THEN ';
    WHILE v_counter <= array_length(v_pk_name,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||v_pk_name[v_counter]||' := NEW.'||v_pk_name[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' ELSIF TG_OP = ''UPDATE'' THEN  ';
    WHILE v_counter <= array_length(v_pk_name,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||v_pk_name[v_counter]||' := OLD.'||v_pk_name[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' ELSIF TG_OP = ''DELETE'' THEN  ';
    WHILE v_counter <= array_length(v_cols,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||v_cols[v_counter]||' := OLD.'||v_cols[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func || 'v_del_time := clock_timestamp(); ';
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' END IF; INSERT INTO @extschema@.'||v_src_table_name||'_pgq ('||v_cols_csv||', mimeo_source_deleted) ';
    v_trigger_func := v_trigger_func || ' VALUES (';
    WHILE v_counter <= array_length(v_cols,1) LOOP
        IF v_counter > 1 THEN
            v_trigger_func := v_trigger_func || ', ';
        END IF;
        v_trigger_func := v_trigger_func||'v_'||v_cols[v_counter];
        v_counter := v_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func ||', v_del_time); RETURN NULL; END $_$;';

v_create_trig := 'CREATE TRIGGER '||v_src_table_name||'_mimeo_trig AFTER INSERT OR DELETE OR UPDATE';
IF p_filter IS NOT NULL THEN
    v_create_trig := v_create_trig || ' OF '||array_to_string(p_filter, ',');
END IF;
v_create_trig := v_create_trig || ' ON '||p_src_table||' FOR EACH ROW EXECUTE PROCEDURE @extschema@.'||v_src_table_name||'_mimeo_queue()';

RAISE NOTICE 'Creating objects on source database (function, trigger & queue table)...';
PERFORM dblink_exec('mimeo_logdel', v_remote_q_table);
PERFORM dblink_exec('mimeo_logdel', v_remote_q_index);
PERFORM dblink_exec('mimeo_logdel', v_trigger_func);
PERFORM dblink_exec('mimeo_logdel', v_create_trig);

-- Only create destination table if it doesn't already exist
SELECT schemaname||'.'||tablename INTO v_dest_check FROM pg_tables WHERE schemaname = v_dest_schema_name AND tablename = v_dest_table_name;
IF v_dest_check IS NULL THEN
    RAISE NOTICE 'Snapshotting source table to pull all current source data...';
    -- Snapshot the table after triggers have been created to ensure all new data after setup is replicated
    v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_snap(source_table, dest_table, dblink, filter, condition) VALUES('
        ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||','
        ||COALESCE(quote_literal(p_filter), 'NULL')||','||COALESCE(quote_literal(p_condition), 'NULL')||')';

    EXECUTE v_insert_refresh_config;

    EXECUTE 'SELECT @extschema@.refresh_snap('||quote_literal(p_dest_table)||', p_index := '||p_index||', p_pulldata := '||p_pulldata||')';
    PERFORM @extschema@.snapshot_destroyer(p_dest_table, 'ARCHIVE');
    -- Ensure destination indexes that are needed for efficient replication are created even if p_index is set false
    IF p_index = false THEN
        RAISE NOTICE 'Adding primary/unique key to table...';
        IF v_key_type = 'primary' THEN
            EXECUTE 'ALTER TABLE '||p_dest_table||' ADD PRIMARY KEY('||array_to_string(v_pk_name, ',')||')';
        ELSE
            EXECUTE 'CREATE UNIQUE INDEX ON '||p_dest_table||' ('||array_to_string(v_pk_name, ',')||')';
        END IF;    
    END IF;
ELSE
    RAISE NOTICE 'Destination table % already exists. No data or indexes were pulled from source', p_dest_table;
END IF;

SELECT count(*) INTO v_col_exists FROM pg_attribute 
    WHERE attrelid = p_dest_table::regclass AND attname = 'mimeo_source_deleted' AND attisdropped = false;
IF v_col_exists < 1 THEN
    EXECUTE 'ALTER TABLE '||p_dest_table||' ADD COLUMN mimeo_source_deleted timestamptz';
ELSE
    RAISE WARNING 'Special column (mimeo_source_deleted) already exists on destination table (%)', p_dest_table;
END IF;

PERFORM dblink_disconnect('mimeo_logdel');

v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_logdel(source_table, dest_table, dblink, control, pk_name, pk_type, last_run, filter, condition) VALUES('
    ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||', '||quote_literal('@extschema@.'||v_src_table_name||'_pgq')||', '
    ||quote_literal(v_pk_name)||', '||quote_literal(v_pk_type)||', '||quote_literal(CURRENT_TIMESTAMP)||','||COALESCE(quote_literal(p_filter), 'NULL')||','
    ||COALESCE(quote_literal(p_condition), 'NULL')||')';
RAISE NOTICE 'Inserting data into config table';

EXECUTE v_insert_refresh_config;

EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

RAISE NOTICE 'Done';

EXCEPTION
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||''',''false'')';
        -- Only cleanup remote objects if replication doesn't exist at all for source table
        EXECUTE 'SELECT count(*) FROM @extschema@.refresh_config_logdel WHERE source_table = '||quote_literal(p_src_table) INTO v_exists;
        IF v_exists = 0 THEN
            PERFORM dblink_exec('mimeo_logdel', 'DROP TABLE IF EXISTS @extschema@.'||v_src_table_name||'_pgq');
            PERFORM dblink_exec('mimeo_logdel', 'DROP TRIGGER IF EXISTS '||v_src_table_name||'_mimeo_trig ON '||p_src_table);
            PERFORM dblink_exec('mimeo_logdel', 'DROP FUNCTION IF EXISTS @extschema@.'||v_src_table_name||'_mimeo_queue()');
        END IF;
        IF dblink_get_connections() @> '{mimeo_logdel}' THEN
            PERFORM dblink_disconnect('mimeo_logdel');
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        IF v_exists = 0 THEN
            RAISE EXCEPTION 'logdel_maker() failure. No mimeo configuration found for source %. Cleaned up source table mimeo objects (queue table, function & trigger) if they existed.  SQLERRM: %', p_src_table, SQLERRM;
        ELSE
            RAISE EXCEPTION 'logdel_maker() failure. Check to see if logdel configuration for % already exists. SQLERRM: % ', p_src_table, SQLERRM;
        END IF;
END
$$;


/*
 *  Updater maker function.
 */ 
CREATE OR REPLACE FUNCTION updater_maker(
    p_src_table text
    , p_control_field text
    , p_dblink_id int
    , p_boundary interval DEFAULT '00:10:00'
    , p_dest_table text DEFAULT NULL
    , p_index boolean DEFAULT true
    , p_filter text[] DEFAULT NULL
    , p_condition text DEFAULT NULL
    , p_pulldata boolean DEFAULT true
    , p_pk_name text[] DEFAULT NULL
    , p_pk_type text[] DEFAULT NULL) 
RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

v_data_source               text;
v_dblink_schema             text;
v_dest_check                text;
v_dest_schema_name          text;
v_dest_table_name           text;
v_dst_active                boolean;
v_field                     text;
v_insert_refresh_config     text;
v_key_type                  text;
v_max_timestamp             timestamptz;
v_old_search_path           text;
v_pk_name                   text[] := p_pk_name;
v_pk_type                   text[] := p_pk_type;
v_remote_key_sql            text;
v_update_refresh_config     text;

BEGIN

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||',public'',''false'')';

IF (p_pk_name IS NULL AND p_pk_type IS NOT NULL) OR (p_pk_name IS NOT NULL AND p_pk_type IS NULL) THEN
    RAISE EXCEPTION 'Cannot manually set primary/unique key field(s) without defining type(s) or vice versa';
END IF;

SELECT data_source INTO v_data_source FROM @extschema@.dblink_mapping WHERE data_source_id = p_dblink_id; 
IF NOT FOUND THEN
	RAISE EXCEPTION 'ERROR: database link ID is incorrect %', p_dblink_id; 
END IF;  

IF p_dest_table IS NULL THEN
    p_dest_table := p_src_table;
END IF;

IF position('.' in p_dest_table) > 0 THEN
    v_dest_schema_name := split_part(p_dest_table, '.', 1); 
    v_dest_table_name := split_part(p_dest_table, '.', 2);
END IF;

PERFORM dblink_connect('mimeo_updater', @extschema@.auth(p_dblink_id));

IF p_pk_name IS NULL AND p_pk_type IS NULL THEN
    -- Either gets the primary key or it gets the first unique index in alphabetical order by index name
    v_remote_key_sql := 'SELECT 
        CASE
            WHEN i.indisprimary IS true THEN ''primary''
            WHEN i.indisunique IS true THEN ''unique''
        END AS key_type,
        ( SELECT array_agg( a.attname ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid
            WHERE a.attnotnull
        ) AS indkey_names,
        ( SELECT array_agg( a.atttypid::regtype::text ORDER by x.r ) 
            FROM pg_attribute a 
            JOIN ( SELECT k, row_number() over () as r 
                    FROM unnest(i.indkey) k ) as x 
            ON a.attnum = x.k AND a.attrelid = i.indrelid
            WHERE a.attnotnull 
        ) AS indkey_types
        FROM pg_index i
        WHERE i.indrelid = '||quote_literal(p_src_table)||'::regclass
            AND (i.indisprimary OR i.indisunique)
        ORDER BY key_type LIMIT 1';

    EXECUTE 'SELECT key_type, indkey_names, indkey_types FROM dblink(''mimeo_updater'', '||quote_literal(v_remote_key_sql)||') t (key_type text, indkey_names text[], indkey_types text[])' 
        INTO v_key_type, v_pk_name, v_pk_type;
END IF;

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'Source table has no valid primary key or unique index';
END IF;

IF p_filter IS NOT NULL THEN
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(p_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary/unique key for source table %', p_src_table;
        END IF;
    END LOOP;
END IF;

-- Only create destination table if it doesn't already exist
SELECT schemaname||'.'||tablename INTO v_dest_check FROM pg_tables WHERE schemaname = v_dest_schema_name AND tablename = v_dest_table_name;
IF v_dest_check IS NULL THEN

    v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_snap(source_table, dest_table, dblink, filter, condition) VALUES('
        ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '||p_dblink_id||','
        ||COALESCE(quote_literal(p_filter), 'NULL')||','||COALESCE(quote_literal(p_condition), 'NULL')||')';    

    RAISE NOTICE 'Snapshotting source table to pull all current source data...';
    EXECUTE v_insert_refresh_config;	
    
    EXECUTE 'SELECT @extschema@.refresh_snap('||quote_literal(p_dest_table)||', p_index := '||p_index||', p_pulldata := '||p_pulldata||')'; 
    PERFORM @extschema@.snapshot_destroyer(p_dest_table, 'ARCHIVE');
    -- Ensure destination indexes that are needed for efficient replication are created even if p_index is set false
    IF p_index = false THEN
        RAISE NOTICE 'Adding primary/unique key to table...';
        IF v_key_type = 'primary' THEN
            EXECUTE 'ALTER TABLE '||p_dest_table||' ADD PRIMARY KEY('||array_to_string(v_pk_name, ',')||')';
        ELSE
            EXECUTE 'CREATE UNIQUE INDEX ON '||p_dest_table||' ('||array_to_string(v_pk_name, ',')||')';
        END IF;    
    END IF;

ELSE
    RAISE NOTICE 'Destination table % already exists. No data or indexes was pulled from source', p_dest_table;
END IF;

PERFORM dblink_disconnect('mimeo_updater');

RAISE NOTICE 'Getting the maximum destination timestamp...';
EXECUTE 'SELECT max('||p_control_field||') FROM '||p_dest_table||';' INTO v_max_timestamp;

v_dst_active := @extschema@.dst_utc_check();

v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_updater(source_table, dest_table, dblink, control, boundary, pk_name, pk_type, last_value, last_run, dst_active, filter, condition) VALUES('
    ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||', '||quote_literal(p_control_field)||', '''
    ||p_boundary||'''::interval, '||quote_literal(v_pk_name)||', '||quote_literal(v_pk_type)||', '
    ||quote_literal(COALESCE(v_max_timestamp, CURRENT_TIMESTAMP))||','||quote_literal(CURRENT_TIMESTAMP)||','||v_dst_active||','
    ||COALESCE(quote_literal(p_filter), 'NULL')||','||COALESCE(quote_literal(p_condition), 'NULL')||')';

RAISE NOTICE 'Inserting data into config table';
EXECUTE v_insert_refresh_config;

-- Remove temp snap from config
EXECUTE 'DELETE FROM @extschema@.refresh_config_snap WHERE source_table = '||quote_literal(p_src_table)||' AND dest_table = '||quote_literal(p_dest_table);

EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

RAISE NOTICE 'Done';

RETURN;

EXCEPTION
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||''',''false'')';
        IF dblink_get_connections() @> '{mimeo_updater}' THEN
            PERFORM dblink_disconnect('mimeo_updater');
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        RAISE EXCEPTION '%', SQLERRM;  
END  
$$;
