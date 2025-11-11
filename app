import ast
import json
import re
import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session
from datetime import datetime

st.set_page_config(page_title="DDM Dual Table DML Dashboard with Approval Workflow", layout="wide")
st.title("DDM Dual Table DML Dashboard with Approval Workflow (TEMP + LOG Enhanced)")

# Get active Snowpark session (assumes Streamlit is running in environment with session available)
session = get_active_session()

# Try adding openpyxl for Excel uploads (best-effort)
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# ----------------------------------------------------------------------
# Table Mappings (Main, Temp, and Log)
# ----------------------------------------------------------------------
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
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",  # using same log structure
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"]
    }
}

# ----------------------------------------------------------------------
# Helpers: sanitize for log + robust parsing for new_value
# ----------------------------------------------------------------------
def sanitize_for_log(obj):
    if obj is None:
        return None
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if isinstance(v, str):
                out[k] = v.replace("\u00a0", " ").strip()
            else:
                try:
                    if isinstance(v, float) and (v != v):
                        out[k] = None
                    else:
                        out[k] = v
                except Exception:
                    out[k] = v
        return out
    return obj

def log_change(log_table, table_name, action, old_value=None, new_value=None):
    old_s = sanitize_for_log(old_value)
    new_s = sanitize_for_log(new_value)
    try:
        old_json = json.dumps(old_s) if old_s is not None else None
    except Exception:
        old_json = json.dumps(str(old_s))
    try:
        new_json = json.dumps(new_s) if new_s is not None else None
    except Exception:
        new_json = json.dumps(str(new_s))

    old_val_sql = f"$$ {old_json} $$" if old_json else "NULL"
    new_val_sql = f"$$ {new_json} $$" if new_json else "NULL"

    insert_sql = f"""
    INSERT INTO {log_table}
    (action, table_name, old_value, new_value, changed_by, changed_at, approved)
    VALUES
    (
        '{action}',
        '{table_name}',
        {old_val_sql},
        {new_val_sql},
        'streamlit_user',
        CURRENT_TIMESTAMP,
        FALSE
    )
    """
    try:
        session.sql(insert_sql).collect()
    except Exception as e:
        st.error(f"Failed to write audit log to {log_table}: {e}")

def parse_new_value(raw):
    if raw is None:
        raise ValueError("new_value is None")
    if isinstance(raw, dict):
        return _sanitize_dict_values(raw)
    s = str(raw).strip()
    if s.startswith("$$") and s.endswith("$$"):
        s = s[2:-2].strip()
    s = s.replace("\u00a0", " ").strip()
    s_json_ready = re.sub(r'(?<!")\bNaN\b(?!")', 'null', s)
    try:
        parsed = json.loads(s_json_ready)
        if isinstance(parsed, dict):
            return _sanitize_dict_values(parsed)
    except Exception:
        pass
    s_py_ready = re.sub(r'\bNaN\b', 'None', s)
    try:
        parsed = ast.literal_eval(s_py_ready)
        if isinstance(parsed, dict):
            return _sanitize_dict_values(parsed)
        else:
            raise ValueError(f"Parsed value is not a dict (type={type(parsed)}).")
    except Exception as e:
        raise ValueError(f"Failed to parse new_value '{raw}' as a dictionary. Error: {e}")

def _sanitize_dict_values(d):
    out = {}
    for k, v in d.items():
        if isinstance(v, str):
            out[k] = v.replace('\u00a0', ' ').strip()
        else:
            try:
                if isinstance(v, float) and (v != v):
                    out[k] = None
                else:
                    out[k] = v
            except Exception:
                out[k] = v
    return out

# ----------------------------------------------------------------------
# File reader helper
# ----------------------------------------------------------------------
def read_uploaded_file(uploaded_file):
    try:
        if uploaded_file.name.endswith(".xlsx"):
            return pd.read_excel(uploaded_file, engine="openpyxl")
        elif uploaded_file.name.endswith(".csv"):
            try:
                return pd.read_csv(uploaded_file, encoding="utf-8")
            except UnicodeDecodeError:
                st.warning("File is not UTF-8 encoded. Trying ISO-8859-1...")
                return pd.read_csv(uploaded_file, encoding="ISO-8859-1")
        else:
            st.error("Unsupported file format. Please upload .xlsx or .csv")
            return None
    except Exception as e:
        st.error(f"Error reading file: {e}")
        return None

# ----------------------------------------------------------------------
# Render UI per table
# ----------------------------------------------------------------------
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    log_table = info["log"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader(f"Main Table: {main_table}")
        try:
            df = session.table(main_table).to_pandas()
            st.dataframe(df, use_container_width=True)
        except Exception as e:
            st.error(f"Could not read main table {main_table}: {e}")

        key_col = required_cols[-1]

        # Upload Section
        st.markdown(f"### Upload Excel or CSV for {table_key} (Inserts into TEMP Table)")
        uploaded_file = st.file_uploader(f"Upload for {table_key}", type=["xlsx", "csv"], key=f"upload_{table_key}")
        if uploaded_file:
            excel_df = read_uploaded_file(uploaded_file)
            if excel_df is not None:
                excel_df.columns = [col.strip().upper() for col in excel_df.columns]
                required_cols_upper = [col.upper() for col in required_cols]
                st.dataframe(excel_df.head())

                if all(col in excel_df.columns for col in required_cols_upper):
                    if st.button(f"Upload to TEMP for {table_key}", key=f"btn_upload_{table_key}"):
                        inserted = 0
                        for _, row in excel_df.iterrows():
                            try:
                                cols = ", ".join(required_cols_upper)
                                vals = ", ".join([
                                    f"'{str(row[col]).replace(\"'\", \"''\")}'" if pd.notna(row[col]) else "NULL"
                                    for col in required_cols_upper
                                ])
                                insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                                session.sql(insert_sql).collect()
                                row_dict = {col: (None if pd.isna(row[col]) else str(row[col]).replace('\u00a0',' ').strip()) for col in required_cols_upper}
                                log_change(log_table, main_table, "INSERT", None, row_dict)
                                inserted += 1
                            except Exception as e:
                                st.error(f"Failed inserting row to {temp_table}: {e}")
                        st.success(f"Uploaded {inserted} rows to TEMP table and logged.")
                else:
                    st.error(f"Missing columns. Required: {required_cols}")

        # Manual Insert
        st.subheader("Manual Insert into TEMP Table")
        with st.form(f"insert_form_{table_key}"):
            inputs = {col: st.text_input(col) for col in required_cols}
            submit = st.form_submit_button("Insert Record")
            if submit:
                try:
                    cols = ", ".join([c.upper() for c in inputs.keys()])
                    vals = ", ".join([
                        f"'{v.replace(\"'\", \"''\")}'" if v != "" else "NULL"
                        for v in inputs.values()
                    ])
                    insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                    session.sql(insert_sql).collect()
                    log_change(log_table, main_table, "INSERT", None, {k.upper(): (None if v=="" else v.replace('\u00a0',' ').strip()) for k,v in inputs.items()})
                    st.success("Record inserted into TEMP and logged.")
                except Exception as e:
                    st.error(f"Failed manual insert: {e}")

        # Update Record
        st.subheader("Update Record (in TEMP Table)")
        with st.form(f"update_form_{table_key}"):
            upd_key = st.text_input(f"{key_col} to Update")
            upd_col = st.selectbox("Column to Update", [c for c in required_cols if c != key_col])
            new_value = st.text_input("New Value")
            submit_upd = st.form_submit_button("Update Record")
            if submit_upd:
                try:
                    old_val_df = session.sql(f"SELECT {upd_col} FROM {temp_table} WHERE {key_col} = '{upd_key.replace(\"'\", \"''\")}'").to_pandas()
                    old_val = old_val_df.iloc[0, 0] if not old_val_df.empty else None
                    update_sql = f"UPDATE {temp_table} SET {upd_col} = '{new_value.replace(\"'\", \"''\")}' WHERE {key_col} = '{upd_key.replace(\"'\", \"''\")}'"
                    session.sql(update_sql).collect()
                    log_change(log_table, main_table, "UPDATE", {upd_col: old_val}, {upd_col: new_value})
                    st.success("Record updated in TEMP and logged.")
                except Exception as e:
                    st.error(f"Failed updating record: {e}")

        # Delete Record
        st.subheader("Delete Record (from TEMP Table)")
        with st.form(f"delete_form_{table_key}"):
            del_key = st.text_input(f"{key_col} to Delete")
            confirm = st.checkbox("Confirm Delete")
            submit_del = st.form_submit_button("Delete Record")
            if submit_del and confirm:
                try:
                    old_val_df = session.sql(f"SELECT * FROM {temp_table} WHERE {key_col} = '{del_key.replace(\"'\", \"''\")}'").to_pandas()
                    old_val = old_val_df.to_dict(orient="records")[0] if not old_val_df.empty else None
                    delete_sql = f"DELETE FROM {temp_table} WHERE {key_col} = '{del_key.replace(\"'\", \"''\")}'"
                    session.sql(delete_sql).collect()
                    log_change(log_table, main_table, "DELETE", old_val, None)
                    st.success("Record deleted from TEMP and logged.")
                except Exception as e:
                    st.error(f"Failed deleting record: {e}")
            elif submit_del:
                st.warning("Please confirm delete before proceeding.")

# ----------------------------------------------------------------------
# Approval Dashboard
# ----------------------------------------------------------------------
st.markdown("## Approval Dashboard")
log_tables = sorted({info["log"] for info in main_tables.values()})
pending_frames = []

for lt in log_tables:
    try:
        df = session.sql(f"SELECT *, '{lt}' as log_table_source FROM {lt} WHERE approved = FALSE").to_pandas()
        if not df.empty:
            pending_frames.append(df)
    except Exception:
        st.warning(f"Could not read log table {lt} (it may not exist or there was an error).")

if not pending_frames:
    st.success("No pending approvals.")
else:
    pending_logs = pd.concat(pending_frames, ignore_index=True)
    st.warning(f"Pending Approvals: {len(pending_logs)} records found.")
    pending_logs.columns = [c.lower() for c in pending_logs.columns]
    display_cols = [c for c in pending_logs.columns if c not in ["log_id", "domain_id", "approved", "approved_by", "approved_at"]]
    display_df = pending_logs[display_cols].copy()
    display_df.reset_index(drop=True, inplace=True)
    if 'approve' not in display_df.columns:
        display_df['approve'] = False

    edited_df = st.data_editor(
        display_df,
        use_container_width=True,
        height=400,
        column_config={
            "approve": st.column_config.CheckboxColumn("Approve", help="Tick to approve this record", width=80)
        },
        hide_index=True
    )

    if st.button("Approve Selected Records"):
        to_approve = edited_df[edited_df['approve'] == True]
        if to_approve.empty:
            st.warning("No rows selected for approval.")
        else:
            approved_count = 0
            for _, log_row in to_approve.iterrows():
                table_name = log_row.get('table_name')
                new_value = log_row.get('new_value')
                changed_by = str(log_row.get('changed_by'))
                changed_at = log_row.get('changed_at')
                action = log_row.get('action')
                log_table_source = log_row.get('log_table_source')

                temp_table = None
                for info in main_tables.values():
                    if info['name'] == table_name:
                        temp_table = info['temp']
                        break

                if not temp_table:
                    st.error(f"TEMP table not found for {table_name}. Skipping.")
                    continue

                try:
                    if pd.isna(changed_at):
                        changed_at_condition = "1=1"
                    else:
                        changed_at_str = str(changed_at).replace("'", "''")
                        changed_at_condition = f"changed_at = '{changed_at_str}'"
                except Exception:
                    changed_at_condition = "1=1"

                approve_sql = f"""
                UPDATE {log_table_source}
                SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP
                WHERE table_name = '{str(table_name).replace(\"'\", \"''\")}'
                AND action = '{str(action).replace(\"'\", \"''\")}'
                AND changed_by = '{changed_by.replace(\"'\", \"''\")}'
                AND {changed_at_condition}
                AND approved = FALSE
                """
                try:
                    session.sql(approve_sql).collect()
                except Exception as e:
                    st.error(f"Failed to mark log as approved in {log_table_source}: {e}")
                    continue

                if new_value:
                    try:
                        new_val_dict = parse_new_value(new_value)
                    except ValueError as e:
                        st.error(f"Error approving row: {e}")
                        continue

                    try:
                        conds = []
                        for k, v in new_val_dict.items():
                            if v is None:
                                conds.append(f"{k} IS NULL")
                            else:
                                safe_val = str(v).replace("'", "''")
                                conds.append(f"{k} = '{safe_val}'")
                        conditions = " AND ".join(conds) if conds else "1=1"
                    except Exception as e:
                        st.error(f"Error building SQL conditions from new_value: {e}")
                        continue

                    try:
                        insert_sql = f"INSERT INTO {table_name} SELECT * FROM {temp_table} WHERE {conditions}"
                        session.sql(insert_sql).collect()
                        session.sql(f"DELETE FROM {temp_table} WHERE {conditions}").collect()
                        approved_count += 1
                    except Exception as e:
                        st.error(f"Failed to apply change from {temp_table} to {table_name}: {e}")
                        continue

            st.success(f"Approved {approved_count} selected rows and applied to main tables.")

# ----------------------------------------------------------------------
# Tabs for main tables
# ----------------------------------------------------------------------
tab1, tab2 = st.tabs(list(main_tables.keys()))
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
