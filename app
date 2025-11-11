# streamlit_app.py
import re
import json
import ast
import numpy as np
import pandas as pd
import streamlit as st
from datetime import datetime, date
from snowflake.snowpark.context import get_active_session

# -------------------------
# App title & session
# -------------------------
st.title("DDM Dual Table DML Dashboard with Approval Workflow (Final)")
session = get_active_session()

# try add openpyxl
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# -------------------------
# Table mappings
# -------------------------
main_tables = {
    "DDM_DOMAIN_VALUE": {
        "name": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE",
        "temp": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_TEMP",
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["TARGETENTITY", "TARGETDOMAIN", "DOMAINVALUE", "DESCRIPTION"]
    },
    "DDM_XREF_DOMAIN_VALUE": {
        "name": "OMNIDDM.COMMON.DDM_XREF_DOMAIN_VALUE",
        "temp": "OMNIDDM.COMMON.DDM_XREF_DOMAIN_VALUE_TEMP",
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"]
    }
}

LOG_TABLE = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"

# -------------------------
# Helpers
# -------------------------
def normalize_string(s):
    """Replace NBSP with regular space and strip. Return same type for non-strings."""
    if s is None:
        return None
    if isinstance(s, str):
        return s.replace("\u00A0", " ").strip()
    return s


def read_uploaded_file(uploaded_file):
    """Read uploaded Excel/CSV into DataFrame and normalize string cells."""
    try:
        if uploaded_file.name.endswith(".xlsx"):
            df = pd.read_excel(uploaded_file, engine="openpyxl")
        elif uploaded_file.name.endswith(".csv"):
            try:
                df = pd.read_csv(uploaded_file, encoding="utf-8")
            except UnicodeDecodeError:
                st.warning("File is not UTF-8 encoded. Trying ISO-8859-1...")
                df = pd.read_csv(uploaded_file, encoding="ISO-8859-1")
        else:
            st.error("Unsupported file format. Please upload .xlsx or .csv")
            return None
        # normalize all string cells
        df = df.applymap(lambda x: normalize_string(x) if isinstance(x, str) else x)
        return df
    except Exception as e:
        st.error("Error reading file: " + str(e))
        return None


def clean_for_json(obj):
    """Convert pandas / numpy types to JSON-serializable primitives."""
    if obj is None:
        return None
    try:
        if pd.isna(obj):
            return None
    except Exception:
        pass
    if isinstance(obj, (pd.Timestamp, datetime)):
        try:
            return obj.isoformat()
        except Exception:
            return str(obj)
    if isinstance(obj, date) and not isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating,)):
        return float(obj)
    if isinstance(obj, (np.bool_,)):
        return bool(obj)
    if isinstance(obj, dict):
        return {str(k): clean_for_json(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple, set, pd.Series)):
        return [clean_for_json(v) for v in obj]
    if isinstance(obj, (str, int, float, bool)):
        return obj
    try:
        return str(obj)
    except Exception:
        return None


def log_change(table_name, action, old_value=None, new_value=None):
    """Insert a log row (JSON-cleaned) into the log table."""
    cleaned_old = clean_for_json(old_value) if old_value is not None else None
    cleaned_new = clean_for_json(new_value) if new_value is not None else None
    old_json = json.dumps(cleaned_old) if cleaned_old is not None else None
    new_json = json.dumps(cleaned_new) if cleaned_new is not None else None
    old_sql_val = "$$ " + old_json + " $$" if old_json is not None else "NULL"
    new_sql_val = "$$ " + new_json + " $$" if new_json is not None else "NULL"

    sql = (
        "INSERT INTO " + LOG_TABLE +
        " (action, table_name, old_value, new_value, changed_by, changed_at, approved) VALUES ("
        "'" + str(action) + "', "
        "'" + str(table_name) + "', "
        + old_sql_val + ", " + new_sql_val + ", "
        "'streamlit_user', CURRENT_TIMESTAMP, FALSE)"
    )
    session.sql(sql).collect()


def parse_new_value(val):
    """Parse JSON / JSON-like / Python literal into dict and normalize string values."""
    if val is None:
        raise ValueError("value is None")
    if isinstance(val, dict):
        return {k: (v.replace("\u00A0", " ").strip() if isinstance(v, str) else v) for k, v in val.items()}
    try:
        if isinstance(val, float) and pd.isna(val):
            raise ValueError("value is NaN")
    except Exception:
        pass
    s = str(val).strip()
    m = re.match(r'^\$\$(.*)\$\$$', s, flags=re.DOTALL)
    if m:
        s = m.group(1).strip()
    # try JSON
    try:
        parsed = json.loads(s)
        if isinstance(parsed, dict):
            return {k: (v.replace("\u00A0", " ").strip() if isinstance(v, str) else v) for k, v in parsed.items()}
    except Exception:
        pass
    # try repair (unquoted keys, single quotes)
    s_fixed = re.sub(r'([{\[,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:', r'\1"\2":', s)
    s_fixed = s_fixed.replace("'", '"')
    try:
        parsed = json.loads(s_fixed)
        if isinstance(parsed, dict):
            return {k: (v.replace("\u00A0", " ").strip() if isinstance(v, str) else v) for k, v in parsed.items()}
    except Exception:
        pass
    # fallback to ast.literal_eval
    try:
        parsed = ast.literal_eval(s)
        if isinstance(parsed, dict):
            return {k: (v.replace("\u00A0", " ").strip() if isinstance(v, str) else v) for k, v in parsed.items()}
        else:
            raise ValueError("literal_eval did not yield dict")
    except Exception as e:
        raise ValueError("Could not parse value: " + str(e) + "; raw=" + repr(val))


def fetch_main_table_sorted(table_name):
    """Fetch main table - try to sort by timestamp-like column if present so newest on top."""
    try:
        df = session.table(table_name).to_pandas()
    except Exception:
        return pd.DataFrame()
    # find candidate timestamp columns
    ts_candidates = [c for c in df.columns if c.lower() in ("approved_at", "changed_at", "created_at", "updated_at", "load_ts")]
    if ts_candidates:
        ts_col = ts_candidates[0]
        try:
            df[ts_col] = pd.to_datetime(df[ts_col], errors="coerce")
            df = df.sort_values(by=ts_col, ascending=False).reset_index(drop=True)
            return df
        except Exception:
            pass
    return df.reset_index(drop=True)


# -------------------------
# UI: render table UI
# -------------------------
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader("Main Table: " + main_table)

        main_df = fetch_main_table_sorted(main_table)
        if not main_df.empty:
            st.dataframe(main_df)
        else:
            st.info("Main table empty or could not be fetched.")

        key_col = required_cols[-1]

        # Upload section
        st.markdown("### Upload Excel or CSV (Inserts into TEMP Table)")
        uploaded_file = st.file_uploader("Upload for " + table_key, type=["xlsx", "csv"])
        if uploaded_file:
            excel_df = read_uploaded_file(uploaded_file)
            if excel_df is not None:
                # uppercase columns for mapping
                excel_df.columns = [c.strip().upper() for c in excel_df.columns]
                required_cols_upper = [c.upper() for c in required_cols]
                st.dataframe(excel_df.head())
                if all(col in excel_df.columns for col in required_cols_upper):
                    if st.button("Upload to TEMP for " + table_key):
                        inserted = 0
                        for _, row in excel_df.iterrows():
                            cols = ", ".join(required_cols_upper)
                            vals_list = []
                            for col in required_cols_upper:
                                v = row.get(col, "")
                                if isinstance(v, str):
                                    v = normalize_string(v)
                                # treat pandas NA as None
                                try:
                                    if pd.isna(v):
                                        v = None
                                except Exception:
                                    pass
                                if v is None or v == "":
                                    vals_list.append("NULL")
                                else:
                                    vals_list.append("'" + str(v).replace("'", "''") + "'")
                            vals = ", ".join(vals_list)
                            insert_sql = "INSERT INTO " + temp_table + " (" + cols + ") VALUES (" + vals + ")"
                            session.sql(insert_sql).collect()
                            # log normalized row (as dict)
                            row_dict = {c: clean_for_json(normalize_string(row.get(c)) if isinstance(row.get(c), str) else row.get(c)) for c in required_cols_upper}
                            log_change(main_table, "INSERT", None, row_dict)
                            inserted += 1
                        st.success(str(inserted) + " rows uploaded to TEMP table and logged.")
                else:
                    st.error("Missing columns. Required: " + str(required_cols))

        # Manual insert
        st.subheader("Manual Insert into TEMP Table")
        with st.form("insert_form_" + table_key):
            inputs = {col: st.text_input(col) for col in required_cols}
            submit = st.form_submit_button("Insert Record")
            if submit:
                cols = ", ".join(inputs.keys())
                vals_parts = []
                for v in inputs.values():
                    if isinstance(v, str):
                        v = normalize_string(v)
                    if v is None or v == "":
                        vals_parts.append("NULL")
                    else:
                        vals_parts.append("'" + str(v).replace("'", "''") + "'")
                vals = ", ".join(vals_parts)
                sql = "INSERT INTO " + temp_table + " (" + cols + ") VALUES (" + vals + ")"
                session.sql(sql).collect()
                log_change(main_table, "INSERT", None, {k: normalize_string(v) if isinstance(v, str) else v for k, v in inputs.items()})
                st.success("Record inserted into TEMP and logged.")

        # Update record in TEMP
        st.subheader("Update Record (in TEMP Table)")
        with st.form("update_form_" + table_key):
            upd_key = st.text_input(key_col + " to Update")
            upd_col = st.selectbox("Column to Update", [c for c in required_cols if c != key_col])
            new_value = st.text_input("New Value")
            submit_upd = st.form_submit_button("Update Record")
            if submit_upd:
                upd_key_norm = normalize_string(upd_key)
                new_val_norm = normalize_string(new_value)
                if upd_key_norm is None or upd_key_norm == "":
                    old_val = None
                else:
                    escaped_key = str(upd_key_norm).replace("'", "''")
                    try:
                        old_val_df = session.sql("SELECT " + upd_col + " FROM " + temp_table + " WHERE " + key_col + " = '" + escaped_key + "'").to_pandas()
                        old_val = old_val_df.iloc[0, 0] if not old_val_df.empty else None
                    except Exception:
                        old_val = None
                escaped_new = "" if new_val_norm is None else str(new_val_norm).replace("'", "''")
                escaped_key = "" if upd_key_norm is None else str(upd_key_norm).replace("'", "''")
                update_sql = "UPDATE " + temp_table + " SET " + upd_col + " = '" + escaped_new + "' WHERE " + key_col + " = '" + escaped_key + "'"
                session.sql(update_sql).collect()
                log_change(main_table, "UPDATE", {upd_col: old_val}, {upd_col: new_value})
                st.success("Record updated in TEMP and logged.")

        # Delete record in TEMP
        st.subheader("Delete Record (from TEMP Table)")
        with st.form("delete_form_" + table_key):
            del_key = st.text_input(key_col + " to Delete")
            confirm = st.checkbox("Confirm Delete")
            submit_del = st.form_submit_button("Delete Record")
            if submit_del and confirm:
                del_key_norm = normalize_string(del_key)
                escaped_key = "" if del_key_norm is None else str(del_key_norm).replace("'", "''")
                try:
                    old_val_df = session.sql("SELECT * FROM " + temp_table + " WHERE " + key_col + " = '" + escaped_key + "'").to_pandas()
                    old_val = old_val_df.to_dict(orient="records")[0] if not old_val_df.empty else None
                except Exception:
                    old_val = None
                delete_sql = "DELETE FROM " + temp_table + " WHERE " + key_col + " = '" + escaped_key + "'"
                session.sql(delete_sql).collect()
                log_change(main_table, "DELETE", old_val, None)
                st.success("Record deleted from TEMP and logged.")
            elif submit_del:
                st.warning("Please confirm delete before proceeding.")


# -------------------------
# Approval Dashboard
# -------------------------
st.markdown("## Approval Dashboard")

try:
    pending_logs = session.sql("SELECT * FROM " + LOG_TABLE + " WHERE approved = FALSE").to_pandas()
except Exception as e:
    st.error("Could not fetch pending logs: " + str(e))
    pending_logs = pd.DataFrame()

if pending_logs.empty:
    st.success("No pending approvals.")
else:
    st.warning("Pending Approvals: " + str(len(pending_logs)) + " records found.")

    pending_logs.columns = [c.lower() for c in pending_logs.columns]
    # Display without internal approval columns
    display_cols = [c for c in pending_logs.columns if c not in ["approved", "approved_by", "approved_at"]]
    display_df = pending_logs[display_cols].copy().reset_index(drop=True)
    if "approve" not in display_df.columns:
        display_df["approve"] = False

    edited_df = st.data_editor(
        display_df,
        use_container_width=True,
        height=400,
        column_config={
            "approve": st.column_config.CheckboxColumn("Approve", help="Tick to approve this record", width=80)
        },
        hide_index=True,
    )

    # Approve Selected Records
    if st.button("Approve Selected Records"):
        to_approve = edited_df[edited_df["approve"] == True]
        if to_approve.empty:
            st.warning("No rows selected for approval.")
        else:
            # Re-fetch pending logs from DB to get authoritative rows (with log_id)
            try:
                pending_logs_db = session.sql("SELECT * FROM " + LOG_TABLE + " WHERE approved = FALSE").to_pandas()
            except Exception as e:
                st.error("Could not fetch pending logs for approval: " + str(e))
                pending_logs_db = pd.DataFrame()

            if pending_logs_db.empty:
                st.info("No pending logs found in DB at approval time.")
            else:
                pending_logs_db.columns = [c.lower() for c in pending_logs_db.columns]

                # build map keyed by (table_name, action, changed_by, changed_at_iso)
                def db_row_key(r):
                    t = r.get("table_name") if r.get("table_name") is not None else ""
                    a = r.get("action") if r.get("action") is not None else ""
                    cb = r.get("changed_by") if r.get("changed_by") is not None else ""
                    ch = r.get("changed_at")
                    try:
                        ch_iso = ch.isoformat() if hasattr(ch, "isoformat") else str(ch)
                    except Exception:
                        ch_iso = str(ch)
                    return (str(t), str(a), str(cb), str(ch_iso))

                db_key_map = {}
                for _, r in pending_logs_db.iterrows():
                    key = db_row_key(r)
                    db_key_map.setdefault(key, []).append(r)

                approved_count = 0
                errors = []

                # helper to create SQL literal or NULL
                def sql_literal_for_value(v):
                    try:
                        if pd.isna(v):
                            return "NULL"
                    except Exception:
                        pass
                    if v is None:
                        return "NULL"
                    if isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_)):
                        return str(v)
                    s = str(v).strip()
                    if re.fullmatch(r"-?\d+(\.\d+)?", s):
                        return s
                    return "'" + s.replace("'", "''") + "'"

                for _, edited_row in to_approve.iterrows():
                    # build lookup key from edited row (these columns are lowercase)
                    table_name = edited_row.get("table_name")
                    action = edited_row.get("action")
                    changed_by = edited_row.get("changed_by")
                    changed_at = edited_row.get("changed_at")
                    try:
                        changed_at_iso = changed_at.isoformat() if hasattr(changed_at, "isoformat") else str(changed_at)
                    except Exception:
                        changed_at_iso = str(changed_at)
                    lookup_key = (str(table_name), str(action), str(changed_by), str(changed_at_iso))

                    matched_list = db_key_map.get(lookup_key)
                    if not matched_list:
                        msg = "No matching DB log found for selected row: " + str(lookup_key)
                        errors.append(msg)
                        st.warning(msg)
                        continue

                    db_row = matched_list.pop(0)  # pop one
                    log_id = db_row.get("log_id")
                    new_value_db = db_row.get("new_value")
                    old_value_db = db_row.get("old_value")
                    table_name_db = db_row.get("table_name")
                    action_db = db_row.get("action")

                    # find temp table mapping
                    temp_table = None
                    for k, info in main_tables.items():
                        if info.get("name") == table_name_db:
                            temp_table = info.get("temp")
                            break
                    if not temp_table:
                        msg = "TEMP mapping not found for " + str(table_name_db) + " (log_id=" + str(log_id) + ")"
                        errors.append(msg)
                        st.error(msg)
                        continue

                    # Build the parsed_condition (dict) from new_value_db / old_value_db
                    parsed_condition = None
                    if action_db and str(action_db).upper() == "DELETE":
                        if old_value_db is not None:
                            try:
                                parsed_condition = parse_new_value(old_value_db)
                            except Exception:
                                try:
                                    parsed_condition = ast.literal_eval(str(old_value_db))
                                except Exception:
                                    parsed_condition = None
                    else:
                        if new_value_db is not None:
                            try:
                                parsed_condition = parse_new_value(new_value_db)
                            except Exception:
                                try:
                                    parsed_condition = ast.literal_eval(str(new_value_db))
                                except Exception:
                                    parsed_condition = None

                    # Build WHERE conditions from parsed_condition (handles NULLs)
                    conditions_exact = None
                    conditions_normalized = None
                    if isinstance(parsed_condition, dict) and parsed_condition:
                        conds_exact = []
                        conds_norm = []
                        for kcol, v in parsed_condition.items():
                            col = str(kcol).upper()
                            if v is None:
                                conds_exact.append(col + " IS NULL")
                                conds_norm.append(col + " IS NULL")
                                continue
                            sval = str(v).strip()
                            sval_norm = sval.replace("\u00A0", " ").strip()
                            if re.fullmatch(r"-?\d+(\.\d+)?", sval):
                                conds_exact.append(col + " = " + sval)
                                conds_norm.append(col + " = " + sval)
                            else:
                                esc = sval.replace("'", "''")
                                conds_exact.append(col + " = '" + esc + "'")
                                esc_norm = sval_norm.replace("'", "''")
                                conds_norm.append("TRIM(REPLACE(" + col + ", CHR(160), ' ')) = '" + esc_norm + "'")
                        conditions_exact = " AND ".join(conds_exact) if conds_exact else None
                        conditions_normalized = " AND ".join(conds_norm) if conds_norm else None

                    # helper to check count in temp
                    def temp_count(where_clause):
                        try:
                            dfc = session.sql("SELECT COUNT(*) AS CNT FROM " + temp_table + " WHERE " + where_clause).to_pandas()
                            return int(dfc.iloc[0]["CNT"]) if not dfc.empty else 0
                        except Exception:
                            return 0

                    use_where = None
                    if conditions_exact:
                        cnt = temp_count(conditions_exact)
                        if cnt > 0:
                            use_where = conditions_exact
                    if (use_where is None) and conditions_normalized:
                        cnt = temp_count(conditions_normalized)
                        if cnt > 0:
                            use_where = conditions_normalized

                    # If no parsed_condition (couldn't parse), fall back to inserting all rows in TEMP once
                    # (this preserves your simplified behavior: one approval -> move current TEMP rows)
                    try:
                        if action_db and str(action_db).upper() in ("INSERT", "UPDATE"):
                            if use_where:
                                # insert matching rows from TEMP -> MAIN
                                insert_sql = "INSERT INTO " + str(table_name_db) + " SELECT * FROM " + temp_table + " WHERE " + use_where
                                session.sql(insert_sql).collect()
                                session.sql("DELETE FROM " + temp_table + " WHERE " + use_where).collect()
                                approved_count += 1
                            else:
                                # fallback: insert everything currently in TEMP (simple behavior)
                                insert_sql = "INSERT INTO " + str(table_name_db) + " SELECT * FROM " + temp_table
                                session.sql(insert_sql).collect()
                                session.sql("DELETE FROM " + temp_table).collect()
                                approved_count += 1

                        elif action_db and str(action_db).upper() == "DELETE":
                            if use_where:
                                session.sql("DELETE FROM " + temp_table + " WHERE " + use_where).collect()
                                approved_count += 1
                            else:
                                session.sql("DELETE FROM " + temp_table).collect()
                                approved_count += 1
                        else:
                            # unknown action - mark as approved (we handle approval marking below)
                            approved_count += 1

                        # mark log approved (prefer log_id, but ensure we only use numeric-like ids)
                        try:
                            # consider log_id valid if it's not None and not NaN
                            if log_id is not None:
                                valid_log_id = False
                                try:
                                    if isinstance(log_id, (int, np.integer)):
                                        valid_log_id = True
                                    else:
                                        # try cast to int if it's a numeric string
                                        int(log_id)
                                        valid_log_id = True
                                except Exception:
                                    valid_log_id = False

                                if valid_log_id:
                                    session.sql("UPDATE " + LOG_TABLE + " SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP WHERE log_id = " + str(int(log_id)) + " AND approved = FALSE").collect()
                                else:
                                    # fallback to safe textual where clause
                                    parts = []
                                    if table_name_db is None:
                                        parts.append("table_name IS NULL")
                                    else:
                                        parts.append("table_name = '" + str(table_name_db).replace("'", "''") + "'")
                                    if action_db is None:
                                        parts.append("action IS NULL")
                                    else:
                                        parts.append("action = '" + str(action_db).replace("'", "''") + "'")
                                    if db_row.get("changed_by") is None:
                                        parts.append("changed_by IS NULL")
                                    else:
                                        parts.append("changed_by = '" + str(db_row.get('changed_by')).replace("'", "''") + "'")
                                    if db_row.get("changed_at") is None:
                                        parts.append("changed_at IS NULL")
                                    else:
                                        try:
                                            chs = db_row.get("changed_at").isoformat() if hasattr(db_row.get("changed_at"), "isoformat") else str(db_row.get("changed_at"))
                                        except Exception:
                                            chs = str(db_row.get("changed_at"))
                                        parts.append("changed_at = '" + str(chs).replace("'", "''") + "'")
                                    where_clause = " AND ".join(parts) + " AND approved = FALSE"
                                    session.sql("UPDATE " + LOG_TABLE + " SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP WHERE " + where_clause).collect()
                            else:
                                # no log_id -> use textual where clause as above
                                parts = []
                                if table_name_db is None:
                                    parts.append("table_name IS NULL")
                                else:
                                    parts.append("table_name = '" + str(table_name_db).replace("'", "''") + "'")
                                if action_db is None:
                                    parts.append("action IS NULL")
                                else:
                                    parts.append("action = '" + str(action_db).replace("'", "''") + "'")
                                if db_row.get("changed_by") is None:
                                    parts.append("changed_by IS NULL")
                                else:
                                    parts.append("changed_by = '" + str(db_row.get('changed_by')).replace("'", "''") + "'")
                                if db_row.get("changed_at") is None:
                                    parts.append("changed_at IS NULL")
                                else:
                                    try:
                                        chs = db_row.get("changed_at").isoformat() if hasattr(db_row.get("changed_at"), "isoformat") else str(db_row.get("changed_at"))
                                    except Exception:
                                        chs = str(db_row.get("changed_at"))
                                    parts.append("changed_at = '" + str(chs).replace("'", "''") + "'")
                                where_clause = " AND ".join(parts) + " AND approved = FALSE"
                                session.sql("UPDATE " + LOG_TABLE + " SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP WHERE " + where_clause).collect()
                        except Exception as e:
                            # we already performed DB moves; just report error marking log
                            errors.append("Could not mark log approved for log_id=" + str(log_id) + ": " + str(e))
                            st.error("Could not mark log approved for log_id=" + str(log_id) + ": " + str(e))

                    except Exception as e:
                        errors.append("DB op failed for log_id=" + str(log_id) + ": " + str(e))
                        st.error("DB op failed for log_id=" + str(log_id) + ": " + str(e))
                        continue

                # end for each selected row

                st.success("Approval run complete. Processed " + str(approved_count) + " selected item(s).")
                if errors:
                    st.warning("Some items had issues; check messages above.")

                # refresh UI: attempt st.experimental_rerun, fallback to st.rerun or browser reload
                try:
                    if hasattr(st, "experimental_rerun"):
                        st.experimental_rerun()
                    elif hasattr(st, "rerun"):
                        st.rerun()
                    else:
                        import streamlit.components.v1 as components
                        components.html("<script>window.location.reload()</script>", height=0)
                except Exception:
                    import streamlit.components.v1 as components
                    components.html("<script>window.location.reload()</script>", height=0)

# -------------------------
# Tabs for main tables
# -------------------------
tab1, tab2 = st.tabs(["DDM_DOMAIN_VALUE", "DDM_XREF_DOMAIN_VALUE"])
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
