#!/bin/bash
# Script: bulk_mysql_dump_to_s3.sh
# Complete working version with S3 and SFTP uploads
# Author: Suyash Ahire

# S3 Configuration (Optional - controlled by flag)
ENABLE_S3_UPLOAD=false  # Set to true to enable S3 uploads
BUCKET="mysql-dumps-for-edw-team"

# SFTP Configuration (Always enabled)
SFTP_HOST="ftp.semtech.com"
SFTP_USER="SW_AMM_UAT"
SFTP_PASSWORD="C8t7699s"
SFTP_REMOTE_DIR="/amm-mysql-dumps"

# SSH Configuration
SSH_USER="imtadmin"
SSH_KEY="/home/sahire/.ssh/id_ed25519"
SSH_PORT="2222"

# MySQL Configuration
MYSQL_USER="root"
MYSQL_DATABASE="inmotion"
MONTHLY_RUN_DATE=15
DATA_RETENTION_MONTHS=3

# Email Configuration
SUMMARY_EMAIL="sahire@semtech.com,sharwani@semtech.com,ataneja@semtech.com,jniwalkar@semtech.com"
#SUMMARY_EMAIL="sahire@semtech.com"

PYTHON_SCRIPT="/home/sahire/edw-data-scripts/create_excel_from_tsv.py"
VENV_DIR="/home/sahire/edw-data-scripts/venv"

# Dynamic variables
DATE=$(date +%Y%m%d_%H%M%S)
MONTH_YEAR=$(date +%b-%Y)
LOG_FILE="/home/sahire/edw-data-scripts/logs/mysql_dump_collection_${DATE}.log"
SUMMARY_FILE="/home/sahire/edw-data-scripts/logs/summary_${DATE}.txt"

# Server list
declare -A SERVERS=(
    ["AMM01"]="amm01.airlink.com"
    ["AMM02"]="amm02.airlink.com"
    ["AMM03"]="amm03.airlink.com"
    ["AMM04"]="amm04.airlink.com"
    ["AMM05"]="amm05.airlink.com"
    ["AMM06"]="amm06.airlink.com"
    ["AMM07"]="amm07.airlink.com"
    ["AMM08"]="amm08.airlink.com"
    ["AMM09"]="amm09.airlink.com"
    ["AMM10"]="amm10.airlink.com"
    ["AMM11"]="amm11.airlink.com"
    ["AMM81"]="amm81.airlink.com"
    ["AMM82"]="amm82.airlink.com"
    ["AMM84"]="amm84.airlink.com"
    ["AMM86"]="amm86.airlink.com"
    ["AMM87"]="amm87.airlink.com"
    ["AMM88"]="amm88.airlink.com"
    ["AMM89"]="amm89.airlink.com"
    ["AMM90"]="amm90.airlink.com"
    ["AMM50"]="amm50.airlink.com"
    ["AMM52"]="amm52.airlink.com"
#   ["AMM99"]="amm99.airlink.com"
)

# Global tracking
declare -A SERVER_STATUS
declare -A SERVER_FILES
declare -A SERVER_ERRORS
declare -A SERVER_SFTP_STATUS

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_monthly_schedule() {
    local current_day=$(date +%d | sed 's/^0//')
    if [ "$current_day" -eq "$MONTHLY_RUN_DATE" ]; then
        log "${GREEN}Today is scheduled run date (${MONTHLY_RUN_DATE}th)${NC}"
        return 0
    else
        log "${YELLOW}Not scheduled run date. Scheduled for ${MONTHLY_RUN_DATE}th${NC}"
        return 1
    fi
}

cleanup_old_data() {
    # Cleanup SFTP (always)
    log "${BLUE}Cleaning up SFTP data older than $DATA_RETENTION_MONTHS months...${NC}"

    if ! command -v lftp &> /dev/null; then
        log "${YELLOW}lftp not available - skipping SFTP cleanup${NC}"
    else
        # Calculate date threshold (files older than this will be deleted)
        local retention_days=$((DATA_RETENTION_MONTHS * 30))
        local threshold_date=$(date -d "$retention_days days ago" +%Y%m%d)
        
        log "${BLUE}Deleting files older than $threshold_date from SFTP${NC}"
        
        # List and delete old files from SFTP
        lftp -u "${SFTP_USER},${SFTP_PASSWORD}" sftp://${SFTP_HOST} << EOF >/dev/null 2>&1
set sftp:auto-confirm yes
cd ${SFTP_REMOTE_DIR}
cls -1 | grep -E "^AMM.*\.xlsx$" | while read file; do
    # Extract date from filename (format: AMMXX_YYYYMMDD_HHMMSS.xlsx)
    file_date=\$(echo "\$file" | grep -oE "[0-9]{8}" | head -1)
    if [ -n "\$file_date" ] && [ "\$file_date" -lt "$threshold_date" ]; then
        rm "\$file"
    fi
done
bye
EOF

        if [ $? -eq 0 ]; then
            log "${GREEN}SFTP cleanup completed${NC}"
        else
            log "${YELLOW}SFTP cleanup had some issues${NC}"
        fi
    fi

    # Cleanup S3 (only if enabled)
    if [ "$ENABLE_S3_UPLOAD" = true ]; then
        log "${BLUE}Cleaning up S3 data older than $DATA_RETENTION_MONTHS months...${NC}"

        if ! command -v aws &> /dev/null; then
            log "${YELLOW}AWS CLI not available - skipping S3 cleanup${NC}"
            return 0
        fi

        local directories=$(aws s3 ls s3://$BUCKET/ 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's/\///g')

        if [ -z "$directories" ]; then
            log "${YELLOW}No S3 directories for cleanup${NC}"
            return 0
        fi

        local deleted_count=0
        local current_date=$(date +%s)
        local retention_seconds=$((DATA_RETENTION_MONTHS * 30 * 24 * 60 * 60))

        for dir in $directories; do
            if [[ $dir =~ ^([A-Z][a-z]{2})-([0-9]{4})$ ]]; then
                local dir_month="${BASH_REMATCH[1]}"
                local dir_year="${BASH_REMATCH[2]}"
                local dir_month_num=$(date -d "01-${dir_month}-${dir_year}" +%m 2>/dev/null)

                if [ -n "$dir_month_num" ]; then
                    local dir_date=$(date -d "${dir_year}-${dir_month_num}-01" +%s 2>/dev/null)
                    local age_seconds=$((current_date - dir_date))

                    if [ $age_seconds -gt $retention_seconds ]; then
                        log "${YELLOW}Deleting S3 directory: $dir${NC}"
                        aws s3 rm s3://$BUCKET/$dir/ --recursive --quiet
                        [ $? -eq 0 ] && deleted_count=$((deleted_count + 1))
                    fi
                fi
            fi
        done

        log "${GREEN}S3 cleanup done. Deleted $deleted_count directories${NC}"
    fi
}

create_monthly_directory() {
    if [ "$ENABLE_S3_UPLOAD" = true ]; then
        log "${BLUE}Creating S3 monthly directory: $MONTH_YEAR${NC}"
        aws s3api put-object --bucket "$BUCKET" --key "$MONTH_YEAR/" >/dev/null 2>&1
        [ $? -eq 0 ] && log "${GREEN}S3 directory created${NC}" || log "${YELLOW}S3 directory creation failed${NC}"
    fi
}

test_ssh_connection() {
    local server_name=$1
    local server_ip=${SERVERS[$server_name]}

    log "${BLUE}Testing SSH: $server_name ($server_ip)${NC}"

    ssh -i "$SSH_KEY" -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$server_ip" "echo 'OK'" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log "${GREEN}SSH successful${NC}"
        return 0
    else
        log "${RED}SSH failed${NC}"
        SERVER_STATUS[$server_name]="FAILED"
        SERVER_ERRORS[$server_name]="SSH connection failed"
        return 1
    fi
}

check_environment() {
    # Check lftp (required for SFTP)
    command -v lftp >/dev/null 2>&1 || { log "${RED}lftp not found - required for SFTP${NC}"; exit 1; }
    log "${GREEN}lftp available${NC}"

    # Check AWS CLI (only if S3 upload is enabled)
    if [ "$ENABLE_S3_UPLOAD" = true ]; then
        if ! command -v aws >/dev/null 2>&1; then
            log "${RED}AWS CLI not found - required when S3 upload is enabled${NC}"
            exit 1
        fi
        
        if ! aws s3 ls s3://$BUCKET >/dev/null 2>&1; then
            log "${RED}Cannot access S3 bucket: $BUCKET${NC}"
            exit 1
        fi
        log "${GREEN}S3 accessible${NC}"
    else
        log "${YELLOW}S3 upload disabled - skipping AWS CLI check${NC}"
    fi

    # Check Python3
    command -v python3 >/dev/null 2>&1 || { log "${RED}Python3 not found${NC}"; exit 1; }

    # Setup virtual environment
    if [ ! -d "$VENV_DIR" ]; then
        log "${YELLOW}Creating venv...${NC}"
        python3 -m venv "$VENV_DIR" || { log "${RED}Venv creation failed${NC}"; exit 1; }
        "$VENV_DIR/bin/pip" install --quiet --upgrade pip openpyxl
    fi

    "$VENV_DIR/bin/python3" -c "import openpyxl" 2>/dev/null || "$VENV_DIR/bin/pip" install --quiet openpyxl

    [ ! -f "$PYTHON_SCRIPT" ] && { log "${RED}Python script not found: $PYTHON_SCRIPT${NC}"; exit 1; }

    log "${GREEN}Environment ready${NC}"
}

create_mysql_dump_script() {
    local server_name=$1
    local script_path="/tmp/mysql_dump_script_${server_name}.sh"

    cat > "$script_path" << 'REMOTE_SCRIPT'
#!/bin/bash
SERVER_NAME="SERVER_NAME_PLACEHOLDER"
DATE="DATE_PLACEHOLDER"
MYSQL_USER="MYSQL_USER_PLACEHOLDER"
MYSQL_DATABASE="MYSQL_DATABASE_PLACEHOLDER"

echo "=== Starting Export on ${SERVER_NAME} ==="

MYSQL_PASSWORD=$(sudo cat /mnt/amm_data/opt/tomcat/webapps/inmotion/config/amm_secure_data 2>/dev/null)
[ -z "$MYSQL_PASSWORD" ] && echo "WARNING: Empty password" || echo "Password OK"

echo "Testing MySQL..."

# Retry MySQL connection up to 5 times with longer delays
RETRY_COUNT=0
MAX_RETRIES=5
MYSQL_CONNECTED=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if [ -n "$MYSQL_PASSWORD" ]; then
        # Add connection timeout of 10 seconds
        if sudo mysql -u $MYSQL_USER -p"$MYSQL_PASSWORD" $MYSQL_DATABASE --connect-timeout=10 -e "SELECT 1" >/dev/null 2>&1; then
            MYSQL_CONNECTED=true
            break
        fi
    else
        if sudo mysql -u $MYSQL_USER $MYSQL_DATABASE --connect-timeout=10 -e "SELECT 1" >/dev/null 2>&1; then
            MYSQL_CONNECTED=true
            break
        fi
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo "MySQL connection attempt $RETRY_COUNT failed, retrying in 5 seconds..."
        sleep 5
    fi
done

if [ "$MYSQL_CONNECTED" = false ]; then
    echo "ERROR: MySQL connection failed after $MAX_RETRIES attempts"
    exit 1
fi

echo "MySQL connection: SUCCESS"

run_query() {
    local query_name=$1
    local query_sql=$2
    local output_file="/tmp/${query_name}_${SERVER_NAME}_${DATE}.tsv"

    echo "Running: $query_name"

    if [ -n "$MYSQL_PASSWORD" ]; then
        sudo mysql -u $MYSQL_USER -p"$MYSQL_PASSWORD" $MYSQL_DATABASE --batch -e "$query_sql" > "$output_file" 2>/tmp/err_${query_name}.log
    else
        sudo mysql -u $MYSQL_USER $MYSQL_DATABASE --batch -e "$query_sql" > "$output_file" 2>/tmp/err_${query_name}.log
    fi

    if [ $? -ne 0 ]; then
        echo "  FAILED: $query_name"
        [ -f /tmp/err_${query_name}.log ] && cat /tmp/err_${query_name}.log
        rm -f "$output_file"
        echo "QUERY_ERROR_${query_name}"
        return 1
    fi

    if [ -s "$output_file" ]; then
        local lines=$(wc -l < "$output_file")
        [ $lines -eq 1 ] && echo "  NO_DATA: $query_name (header only)" && echo "QUERY_NODATA_${query_name}" || echo "  SUCCESS: $query_name ($((lines-1)) rows)"
    else
        echo "  NO_DATA: $query_name (empty)"
        echo "QUERY_NODATA_${query_name}"
        echo -e "No Data Available" > "$output_file"
    fi
    return 0
}

QUERY_SUCCESS=0

QUERY1='WITH RECURSIVE grp_path (groupid, label, rootid, rootlabel) AS (SELECT groupid, label, groupid AS rootid, label AS rootlabel FROM im_group WHERE parentgroupid = 0 UNION ALL SELECT c.groupid, c.label, sup.rootid, sup.rootlabel FROM grp_path AS sup JOIN im_group c ON sup.groupid = c.parentgroupid) SELECT rootid, rootlabel AS rootgroup, groupid, label AS groupname FROM grp_path ORDER BY rootid, groupid;'
run_query "Group_Hierarchy_Path" "$QUERY1" && QUERY_SUCCESS=$((QUERY_SUCCESS + 1))

QUERY2='SELECT grp.label AS groupname, grp.groupid, count(*) AS num_gateways FROM im_group grp JOIN im_node node ON grp.groupid = node.groupid JOIN im_lateststatitem latest ON latest.nodeid = node.nodeid JOIN im_stat stat ON latest.statid = stat.statid WHERE grp.groupid IS NOT NULL AND node.groupid <> 0 AND stat.statlabel = '\''ReportIdleTime'\'' AND latest.value < 2592000 GROUP BY grp.groupid, grp.label ORDER BY grp.label, grp.groupid;'
run_query "Gateway_Count_By_Group" "$QUERY2" && QUERY_SUCCESS=$((QUERY_SUCCESS + 1))

QUERY3='SELECT perm.groupid, g.label AS groupname, u.loginname AS username, u.email FROM im_user u JOIN im_permissiongroup perm ON u.userid = perm.userid JOIN im_group g ON perm.groupid = g.groupid ORDER BY perm.groupid, g.label;'
run_query "User_List_With_Groups" "$QUERY3" && QUERY_SUCCESS=$((QUERY_SUCCESS + 1))

QUERY4='SELECT COUNT(*) AS gateways_registered_last_30_days FROM im_audit WHERE time > DATE_SUB(NOW(), INTERVAL 30 DAY) AND text LIKE '\''%create node %'\'';'
run_query "Gateways_Registered_Last_30_Days" "$QUERY4" && QUERY_SUCCESS=$((QUERY_SUCCESS + 1))





QUERY5='WITH RECURSIVE grp_path (path_grpid, label, rootid, rootname, fullpath) AS (SELECT groupid, label, groupid AS rootid, label AS rootname, label AS fullpath FROM im_group WHERE parentgroupid = 0 UNION ALL SELECT c.groupid, c.label, sup.rootid, sup.label, CONCAT(sup.rootname, "...", c.label) FROM im_group c INNER JOIN grp_path sup ON sup.path_grpid = c.parentgroupid), hbt (statnode, statval) AS (SELECT l.nodeid, l.value FROM im_lateststatitem l INNER JOIN im_stat s ON s.statid = l.statid WHERE s.statlabel = "ReportIdleTime") SELECT n.label AS serial, n.name, grp_path.fullpath, n.type AS device_type, CASE WHEN n.platform = 0 THEN "MG90" WHEN n.platform = 1 THEN "oMG2000" WHEN n.platform = 2 THEN "oMG500" WHEN n.platform = 4 THEN "MG90" WHEN n.platform = 64 THEN "GNX3" WHEN n.platform = 65 THEN "GNX6" WHEN n.platform = 100 THEN "ES440" WHEN n.platform = 101 THEN "ES450" WHEN n.platform = 107 THEN "GX400" WHEN n.platform = 108 THEN "GX440" WHEN n.platform = 109 THEN "GX450" WHEN n.platform = 110 THEN "LS300" WHEN n.platform = 113 THEN "RV50" WHEN n.platform = 114 THEN "MP70" WHEN n.platform = 115 THEN "RV50X" WHEN n.platform = 117 THEN "LX60" WHEN n.platform = 118 THEN "LX40" WHEN n.platform = 119 THEN "RV55" WHEN n.platform = 120 THEN "XR60" WHEN n.platform = 121 THEN "XR80" WHEN n.platform = 122 THEN "XR90" WHEN n.platform = 123 THEN "RX55" ELSE CONCAT(n.platform, "_missing") END AS platform, DATE_SUB(NOW(), INTERVAL statval SECOND) as last_comm FROM im_node n LEFT JOIN grp_path ON path_grpid = n.groupid LEFT JOIN hbt ON statnode = n.nodeid ORDER BY last_comm;'
run_query "Device_Level_Data" "$QUERY5" && QUERY_SUCCESS=$((QUERY_SUCCESS + 1))




TSV_COUNT=$(ls -1 /tmp/*_${SERVER_NAME}_${DATE}.tsv 2>/dev/null | wc -l)
[ $TSV_COUNT -eq 0 ] && { echo "ERROR: No TSV files"; exit 1; }

echo "TSV files: $TSV_COUNT"
ls -lh /tmp/*_${SERVER_NAME}_${DATE}.tsv

TAR_FILE="/tmp/mysql_results_${SERVER_NAME}_${DATE}.tar.gz"
cd /tmp && tar -czf "$TAR_FILE" *_${SERVER_NAME}_${DATE}.tsv 2>&1

[ ! -f "$TAR_FILE" ] && { echo "ERROR: Tar failed"; exit 1; }
tar -tzf "$TAR_FILE" >/dev/null 2>&1 || { echo "ERROR: Tar corrupted"; exit 1; }

echo "SUCCESS: Results packaged"
echo "DUMP_FILE: ${TAR_FILE}"
echo "FILE_SIZE: $(ls -lh ${TAR_FILE} | awk '{print $5}')"

rm -f /tmp/*_${SERVER_NAME}_${DATE}.tsv /tmp/err_*.log
exit 0
REMOTE_SCRIPT

    sed -i "s/SERVER_NAME_PLACEHOLDER/$server_name/g" "$script_path"
    sed -i "s/DATE_PLACEHOLDER/$DATE/g" "$script_path"
    sed -i "s/MYSQL_USER_PLACEHOLDER/$MYSQL_USER/g" "$script_path"
    sed -i "s/MYSQL_DATABASE_PLACEHOLDER/$MYSQL_DATABASE/g" "$script_path"

    echo "$script_path"
}

create_excel_from_tsv() {
    local server_name=$1
    local tsv_dir=$2
    local excel_output=$3

    log "${BLUE}Creating Excel for $server_name...${NC}"

    stdbuf -oL -eL "$VENV_DIR/bin/python3" -u "$PYTHON_SCRIPT" "$tsv_dir" "$excel_output" "$server_name" | while IFS= read -r line; do
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${BLUE}  PY: ${line}${NC}"
    done

    [ -f "$excel_output" ] && { log "${GREEN}Excel created${NC}"; return 0; } || { log "${RED}Excel failed${NC}"; return 1; }
}

upload_to_s3() {
    local file_path=$1
    local s3_path="s3://$BUCKET/$MONTH_YEAR/$(basename $file_path)"

    # Log to file only (not stdout) to avoid polluting return value
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading to S3: $s3_path" >> "$LOG_FILE"

    if aws s3 cp "$file_path" "$s3_path" --storage-class STANDARD_IA --quiet 2>/dev/null; then
        local size=$(ls -lh "$file_path" | awk '{print $5}')
        echo "$(date '+%Y-%m-%d %H:%M:%S') - S3 upload successful (Size: ${size})" >> "$LOG_FILE"
        # Return only the essential info - no log output
        echo "$s3_path|$size"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - S3 upload failed" >> "$LOG_FILE"
    return 1
}

upload_to_sftp() {
    local file_path=$1
    local server_name=$2

    if ! command -v lftp &> /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SFTP skipped - lftp not installed" >> "$LOG_FILE"
        SERVER_SFTP_STATUS[$server_name]="FAILED"
        return 1
    fi

    local filename=$(basename "$file_path")
    local filesize=$(ls -lh "$file_path" | awk '{print $5}')

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading to SFTP: ${SFTP_HOST}${SFTP_REMOTE_DIR}/${filename}" >> "$LOG_FILE"

    lftp -u "${SFTP_USER},${SFTP_PASSWORD}" sftp://${SFTP_HOST} << EOF >/tmp/sftp_${server_name}.log 2>&1
set sftp:auto-confirm yes
set net:timeout 30
cd ${SFTP_REMOTE_DIR}
put ${file_path}
bye
EOF

    if [ $? -eq 0 ] && ! grep -qi "error\|failed" /tmp/sftp_${server_name}.log; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SFTP upload successful" >> "$LOG_FILE"
        SERVER_SFTP_STATUS[$server_name]="SUCCESS"
        rm -f /tmp/sftp_${server_name}.log
        # Return path and size
        echo "${SFTP_HOST}${SFTP_REMOTE_DIR}/${filename}|${filesize}"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - SFTP upload failed" >> "$LOG_FILE"
    SERVER_SFTP_STATUS[$server_name]="FAILED"
    rm -f /tmp/sftp_${server_name}.log
    return 1
}

process_server() {
    local server_name=$1
    local server_ip=${SERVERS[$server_name]}

    log "${YELLOW}===== Processing: $server_name ($server_ip) =====${NC}"

    test_ssh_connection "$server_name" || return 1

    log "${BLUE}Creating remote script...${NC}"
    local script_path=$(create_mysql_dump_script "$server_name")

    log "${BLUE}Copying script...${NC}"
    if ! scp -i "$SSH_KEY" -P "$SSH_PORT" -q "$script_path" "$SSH_USER@$server_ip:/tmp/" 2>/dev/null; then
        log "${RED}SCP failed${NC}"
        SERVER_STATUS[$server_name]="FAILED"
        SERVER_ERRORS[$server_name]="SCP script copy failed"
        rm -f "$script_path"
        return 1
    fi

    log "${GREEN}Script copied${NC}"

    log "${BLUE}Executing queries...${NC}"
    local output_file="/tmp/remote_out_${server_name}_${DATE}.log"

    ssh -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$server_ip" "bash /tmp/mysql_dump_script_${server_name}.sh" > "$output_file" 2>&1
    local exit_code=$?

    log "${BLUE}Remote output:${NC}"
    grep -v "WARNING\|Sierra Wireless\|affiliates\|authorized\|expectation\|intercepted\|disciplinary" "$output_file" | while read line; do
        [ -n "$line" ] && log "${BLUE}  >> $line${NC}"
    done

    # Analyze results
    local query_errors=0
    local query_nodata=0

    grep -F "QUERY_ERROR_Group_Hierarchy_Path" "$output_file" >/dev/null 2>&1 && query_errors=$((query_errors + 1))
    grep -F "QUERY_ERROR_Gateway_Count_By_Group" "$output_file" >/dev/null 2>&1 && query_errors=$((query_errors + 1))
    grep -F "QUERY_ERROR_User_List_With_Groups" "$output_file" >/dev/null 2>&1 && query_errors=$((query_errors + 1))
    grep -F "QUERY_ERROR_Gateways_Registered_Last_30_Days" "$output_file" >/dev/null 2>&1 && query_errors=$((query_errors + 1))	
    grep -F "QUERY_ERROR_Device_Level_Data" "$output_file" >/dev/null 2>&1 && query_errors=$((query_errors + 1))
    
    grep -F "QUERY_NODATA_Group_Hierarchy_Path" "$output_file" >/dev/null 2>&1 && query_nodata=$((query_nodata + 1))
    grep -F "QUERY_NODATA_Gateway_Count_By_Group" "$output_file" >/dev/null 2>&1 && query_nodata=$((query_nodata + 1))
    grep -F "QUERY_NODATA_User_List_With_Groups" "$output_file" >/dev/null 2>&1 && query_nodata=$((query_nodata + 1))
    grep -F "QUERY_NODATA_Gateways_Registered_Last_30_Days" "$output_file" >/dev/null 2>&1 && query_nodata=$((query_nodata + 1))
    grep -F "QUERY_NODATA_Device_Level_Data" "$output_file" >/dev/null 2>&1 && query_nodata=$((query_nodata + 1))
    
    log "${BLUE}Analysis: NoData=$query_nodata, Errors=$query_errors${NC}"

    [ $exit_code -ne 0 ] && { log "${RED}Remote script failed${NC}"; SERVER_STATUS[$server_name]="FAILED"; SERVER_ERRORS[$server_name]="Script execution failed"; rm -f "$script_path" "$output_file"; return 1; }

    local tar_file=$(grep "DUMP_FILE:" "$output_file" | awk '{print $2}')
    [ -z "$tar_file" ] && { log "${RED}No tar file${NC}"; SERVER_STATUS[$server_name]="FAILED"; SERVER_ERRORS[$server_name]="No output"; rm -f "$script_path" "$output_file"; return 1; }

    log "${BLUE}Downloading tar...${NC}"
    local local_tar="/tmp/mysql_results_${server_name}_${DATE}.tar.gz"

    scp -i "$SSH_KEY" -P "$SSH_PORT" -q "$SSH_USER@$server_ip:$tar_file" "$local_tar" 2>/dev/null || { log "${RED}Download failed${NC}"; SERVER_STATUS[$server_name]="FAILED"; SERVER_ERRORS[$server_name]="SCP download failed"; rm -f "$script_path" "$output_file"; return 1; }

    log "${GREEN}Downloaded ($(ls -lh $local_tar | awk '{print $5}'))${NC}"

    tar -tzf "$local_tar" >/dev/null 2>&1 || { log "${RED}Corrupted tar${NC}"; SERVER_STATUS[$server_name]="FAILED"; SERVER_ERRORS[$server_name]="Corrupted tar"; rm -f "$local_tar" "$script_path" "$output_file"; return 1; }

    local tsv_dir="/tmp/tsv_${server_name}_${DATE}"
    mkdir -p "$tsv_dir"
    tar -xzf "$local_tar" -C "$tsv_dir" 2>/dev/null

    for tsv in "$tsv_dir"/*_${server_name}_${DATE}.tsv; do
        [ -f "$tsv" ] && mv "$tsv" "$tsv_dir/$(basename "$tsv" | sed "s/_${server_name}_${DATE}//")"
    done

    # New filename format: SERVERNAME_YYYYMMDD_HHMMSS.xlsx
    local excel_file="/tmp/${server_name}_$(date +%Y%m%d_%H%M%S).xlsx"

    create_excel_from_tsv "$server_name" "$tsv_dir" "$excel_file" || { log "${RED}Excel failed${NC}"; SERVER_STATUS[$server_name]="FAILED"; SERVER_ERRORS[$server_name]="Excel creation failed"; rm -rf "$tsv_dir" "$local_tar" "$script_path" "$output_file"; return 1; }

    # Upload to S3 (if enabled)
    local s3_status="DISABLED"
    local s3_path=""
    local s3_size=""
    
    if [ "$ENABLE_S3_UPLOAD" = true ]; then
        log "${BLUE}Uploading to S3...${NC}"
        local s3_result=$(upload_to_s3 "$excel_file" "$server_name")
        if [ $? -eq 0 ]; then
            s3_path=$(echo "$s3_result" | cut -d'|' -f1)
            s3_size=$(echo "$s3_result" | cut -d'|' -f2)
            s3_status="SUCCESS"
            log "${GREEN}S3 upload successful${NC}"
        else
            s3_status="FAILED"
            log "${YELLOW}S3 upload failed (non-critical)${NC}"
        fi
    else
        log "${YELLOW}S3 upload disabled${NC}"
    fi

    # Upload to SFTP (mandatory)
    log "${BLUE}Uploading to SFTP...${NC}"
    local sftp_result=$(upload_to_sftp "$excel_file" "$server_name")
    if [ $? -ne 0 ]; then
        log "${RED}SFTP upload failed${NC}"
        SERVER_STATUS[$server_name]="FAILED"
        SERVER_ERRORS[$server_name]="SFTP upload failed"
        rm -rf "$tsv_dir" "$local_tar" "$excel_file" "$script_path" "$output_file"
        return 1
    fi

    local sftp_path=$(echo "$sftp_result" | cut -d'|' -f1)
    local sftp_size=$(echo "$sftp_result" | cut -d'|' -f2)

    # Set status
    if [ $query_nodata -eq 5 ]; then
        SERVER_STATUS[$server_name]="NO_DATA"
        SERVER_ERRORS[$server_name]="Queries OK but no data (empty database)"
    else
        SERVER_STATUS[$server_name]="SUCCESS"
    fi

    # Build file location info
    if [ "$ENABLE_S3_UPLOAD" = true ] && [ "$s3_status" = "SUCCESS" ]; then
        SERVER_FILES[$server_name]="S3: $s3_path ($s3_size)
SFTP: $sftp_path ($sftp_size)"
    else
        SERVER_FILES[$server_name]="SFTP: $sftp_path ($sftp_size)"
        [ "$ENABLE_S3_UPLOAD" = true ] && SERVER_FILES[$server_name]="${SERVER_FILES[$server_name]}
S3: FAILED"
    fi

    rm -rf "$tsv_dir" "$local_tar" "$excel_file" "$script_path" "$output_file"
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$server_ip" "rm -f $tar_file /tmp/mysql_dump_script_${server_name}.sh" 2>/dev/null

    log "${GREEN}✓ Done: $server_name${NC}"
    return 0
}

generate_email_summary() {
    local success=$1
    local total=$2

    local failed=0
    local nodata=0

    for srv in "${!SERVER_STATUS[@]}"; do
        [ "${SERVER_STATUS[$srv]}" == "FAILED" ] && failed=$((failed + 1))
        [ "${SERVER_STATUS[$srv]}" == "NO_DATA" ] && nodata=$((nodata + 1))
    done

    local rate=0
    [ $total -gt 0 ] && rate=$((success * 100 / total))

    cat > "$SUMMARY_FILE" << EOF
========================================
AMM MySQL DB Collection Summary: $MONTH_YEAR
========================================
Date: $(date)

OVERALL:
Total: $total | Success: $success | No Data: $nodata | Failed: $failed
Success Rate: ${rate}%

DETAILED STATUS:
========================================

EOF

    for srv in $(echo "${!SERVERS[@]}" | tr ' ' '\n' | sort); do
        local ip=${SERVERS[$srv]}
        local status=${SERVER_STATUS[$srv]:-"NOT_RUN"}
        local sftp=${SERVER_SFTP_STATUS[$srv]:-"N/A"}

        echo "Server: $srv ($ip)" >> "$SUMMARY_FILE"
        echo "Status: $status | SFTP: $sftp" >> "$SUMMARY_FILE"

        case "$status" in
            SUCCESS)
                echo "Result: Success with data" >> "$SUMMARY_FILE"
                echo "File: ${SERVER_FILES[$srv]}" >> "$SUMMARY_FILE"
                ;;
            NO_DATA)
                echo "Result: Queries OK but no data" >> "$SUMMARY_FILE"
                echo "Reason: ${SERVER_ERRORS[$srv]}" >> "$SUMMARY_FILE"
                [ -n "${SERVER_FILES[$srv]}" ] && echo "File: ${SERVER_FILES[$srv]}" >> "$SUMMARY_FILE"
                ;;
            FAILED)
                echo "Result: Failed" >> "$SUMMARY_FILE"
                echo "Error: ${SERVER_ERRORS[$srv]}" >> "$SUMMARY_FILE"
                ;;
        esac

        echo "---" >> "$SUMMARY_FILE"
    done

    cat >> "$SUMMARY_FILE" << EOF

STORAGE:
SFTP: sftp://$SFTP_HOST$SFTP_REMOTE_DIR/
EOF

    if [ "$ENABLE_S3_UPLOAD" = true ]; then
        echo "S3: s3://$BUCKET/$MONTH_YEAR/" >> "$SUMMARY_FILE"
    else
        echo "S3: DISABLED" >> "$SUMMARY_FILE"
    fi

    cat >> "$SUMMARY_FILE" << EOF

Log: $LOG_FILE
========================================
EOF

    cat "$SUMMARY_FILE"

    if command -v sendmail >/dev/null 2>&1; then
        {
            echo "To: $SUMMARY_EMAIL"
            echo "From: AMM-DevOpsTeam<monit@amm.airlink.com>"
            echo "Reply-To: noreply@amm.airlink.com"
            echo "Subject: AMM MySQL DB Collection Summary: $MONTH_YEAR"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo ""
            cat "$SUMMARY_FILE"
        } | sendmail -t -f monit@amm.airlink.com
        
        if [ $? -eq 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Email summary sent to $SUMMARY_EMAIL" >> "$LOG_FILE"
            log "${GREEN}Email summary sent to $SUMMARY_EMAIL${NC}"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Failed to send email summary" >> "$LOG_FILE"
            log "${RED}Email failed to send summary${NC}"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Sendmail not available. Summary saved to: $SUMMARY_FILE" >> "$LOG_FILE"
        log "${YELLOW}Sendmail not available. Summary saved to: $SUMMARY_FILE${NC}"
    fi
}

process_all_servers() {
    local success=0

    log "${BLUE}Starting ${#SERVERS[@]} servers...${NC}"

    for srv in "${!SERVERS[@]}"; do
        process_server "$srv" && [ "${SERVER_STATUS[$srv]}" == "SUCCESS" ] && success=$((success + 1))
        log "====="
    done

    generate_email_summary "$success" "${#SERVERS[@]}"
}

usage() {
    cat << EOF
Usage: $0 [options]

OPTIONS:
  -h, --help      Help
  -t, --test      Test SSH
  -s, --server    Single server
  -f, --force     Force run
  -c, --cleanup   Cleanup only
  -l, --list      List servers
EOF
}

test_connections_only() {
    log "${BLUE}Testing SSH...${NC}"
    local ok=0
    for srv in "${!SERVERS[@]}"; do
        test_ssh_connection "$srv" && ok=$((ok + 1))
    done
    log "${BLUE}Results: $ok/${#SERVERS[@]} OK${NC}"
}

main() {
    local force=false
    local cleanup_only=false
    local test_only=false
    local single=""

    mkdir -p "$(dirname "$LOG_FILE")"

    log "${BLUE}=== MySQL Dump Started ===${NC}"
    log "${BLUE}Date: $(date)${NC}"

    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            -t|--test) test_only=true; shift ;;
            -s|--server)
                [ -z "$2" ] && { echo "Server name required"; exit 1; }
                [[ ! ${SERVERS[$2]+_} ]] && { echo "Server $2 not found"; exit 1; }
                single="$2"
                force=true
                shift 2
                ;;
            -l|--list)
                for s in "${!SERVERS[@]}"; do echo "  $s -> ${SERVERS[$s]}"; done | sort
                exit 0
                ;;
            -f|--force) force=true; shift ;;
            -c|--cleanup) cleanup_only=true; shift ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done

    check_environment

    [ "$test_only" = true ] && { test_connections_only; exit 0; }
    [ "$cleanup_only" = true ] && { cleanup_old_data; exit 0; }

    [ "$force" = false ] && ! check_monthly_schedule && { log "${YELLOW}Use --force${NC}"; exit 0; }

    # Create S3 monthly directory if S3 upload is enabled
    create_monthly_directory
    
    # Cleanup old data
    cleanup_old_data

    if [ -n "$single" ]; then
        process_server "$single"
        local res=$?
        local count=0
        [ $res -eq 0 ] && [ "${SERVER_STATUS[$single]}" == "SUCCESS" ] && count=1
        generate_email_summary "$count" 1
    else
        process_all_servers
    fi

    log "${GREEN}=== Done ===${NC}"
}

main "$@"
