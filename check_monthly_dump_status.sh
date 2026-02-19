#!/bin/bash
# MySQL Dump Status Monitoring Script - S3 and SFTP Check

BUCKET="mysql-dumps-for-edw-team"
CURRENT_MONTH_YEAR=$(date +%b-%Y)
EXPECTED_COUNT=3

SFTP_HOST="ftp.semtech.com"
SFTP_USER="SW_AMM_UAT"
SFTP_PASSWORD="C8t7699s"
SFTP_REMOTE_DIR="/amm-mysql-dumps"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================"
echo "MySQL Dump Status Check"
echo "Month: $CURRENT_MONTH_YEAR"
echo "Date: $(date)"
echo -e "========================================${NC}"
echo ""

check_s3() {
    echo -e "${BLUE}=== S3 Check ===${NC}"
    echo "Location: s3://$BUCKET/$CURRENT_MONTH_YEAR/"

    if aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ >/dev/null 2>&1; then
        local count=$(aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ --recursive | grep -v "/$" | wc -l)

        echo -e "${GREEN}✓ Directory exists${NC}"
        echo "  Files: $count"

        if [ $count -ge $EXPECTED_COUNT ]; then
            echo -e "${GREEN}  ✓ All $EXPECTED_COUNT dumps present${NC}"
            echo ""
            echo "  Files:"
            aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ --recursive | grep -v "/$" | awk '{print "    " $4 " (" $3 ")"}'
            return 0
        else
            echo -e "${YELLOW}  ⚠ Only $count dumps, expected $EXPECTED_COUNT${NC}"
            aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ --recursive | grep -v "/$" | awk '{print "    " $4}'
            return 1
        fi
    else
        echo -e "${RED}✗ Directory not found${NC}"
        return 1
    fi
}

check_sftp() {
    echo ""
    echo -e "${BLUE}=== SFTP Check ===${NC}"
    echo "Location: sftp://$SFTP_HOST$SFTP_REMOTE_DIR/"

    if ! command -v lftp &> /dev/null; then
        echo -e "${YELLOW}  ⚠ lftp not installed${NC}"
        return 2
    fi

    local list="/tmp/sftp_list_$$.txt"
    local month_pattern=$(date +%Y%m)

    lftp -u "${SFTP_USER},${SFTP_PASSWORD}" sftp://${SFTP_HOST} << EOF > "$list" 2>&1
set sftp:auto-confirm yes
set net:timeout 30
cd ${SFTP_REMOTE_DIR}
ls
bye
EOF

    if [ $? -ne 0 ] || grep -qi "error\|failed\|no such" "$list"; then
        echo -e "${RED}✗ Directory not accessible${NC}"
        grep -i "error\|failed" "$list" | head -2 | sed 's/^/  /'
        rm -f "$list"
        return 1
    fi

    local count=$(grep "_${month_pattern}_" "$list" | wc -l)

    echo -e "${GREEN}✓ Directory accessible${NC}"
    echo "  Files for $CURRENT_MONTH_YEAR: $count"

    if [ $count -ge $EXPECTED_COUNT ]; then
        echo -e "${GREEN}  ✓ All $EXPECTED_COUNT dumps present${NC}"
        echo ""
        echo "  Files:"
        grep "_${month_pattern}_" "$list" | awk '{print "    " $NF}'
        rm -f "$list"
        return 0
    else
        echo -e "${YELLOW}  ⚠ Only $count dumps, expected $EXPECTED_COUNT${NC}"
        grep "_${month_pattern}_" "$list" | awk '{print "    " $NF}' | head -10
        rm -f "$list"
        return 1
    fi
}

compare_locations() {
    echo ""
    echo -e "${BLUE}=== Comparison ===${NC}"

    local s3_files=$(aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ --recursive 2>/dev/null | grep -v "/$" | awk '{print $4}' | xargs -n1 basename | sort)
    local s3_count=$(echo "$s3_files" | grep -v "^$" | wc -l)

    local sftp_files=""
    local sftp_count=0
    local month_pattern=$(date +%Y%m)

    if command -v lftp &> /dev/null; then
        local list="/tmp/sftp_cmp_$$.txt"
        lftp -u "${SFTP_USER},${SFTP_PASSWORD}" sftp://${SFTP_HOST} << EOF > "$list" 2>&1
set sftp:auto-confirm yes
cd ${SFTP_REMOTE_DIR}
ls
bye
EOF

        if [ $? -eq 0 ] && ! grep -qi "error" "$list"; then
            sftp_files=$(grep "_${month_pattern}_" "$list" | awk '{print $NF}' | sort)
            sftp_count=$(echo "$sftp_files" | grep -v "^$" | wc -l)
        fi
        rm -f "$list"
    fi

    echo "S3: $s3_count files | SFTP: $sftp_count files"

    if [ $s3_count -eq $sftp_count ] && [ $s3_count -eq $EXPECTED_COUNT ]; then
        echo -e "${GREEN}✓ Both locations have complete dumps${NC}"
    else
        echo -e "${YELLOW}⚠ Locations may not be in sync${NC}"
    fi
}

s3_status=0
sftp_status=0

check_s3
s3_status=$?

check_sftp
sftp_status=$?

[ $s3_status -eq 0 ] || [ $sftp_status -eq 0 ] && compare_locations

echo ""
echo -e "${BLUE}=== Overall ===${NC}"

if [ $s3_status -eq 0 ] && [ $sftp_status -eq 0 ]; then
    echo -e "${GREEN}✓ HEALTHY: Both S3 and SFTP complete${NC}"
elif [ $s3_status -eq 0 ] || [ $sftp_status -eq 0 ]; then
    echo -e "${YELLOW}⚠ PARTIAL: One location has issues${NC}"
else
    echo -e "${RED}✗ CRITICAL: Both locations have issues${NC}"
fi

echo ""
echo "Recent S3 directories:"
aws s3 ls s3://$BUCKET/ | grep "PRE" | tail -6

echo ""
echo "Jumphost disk:"
df -h /tmp

echo ""
echo "Check done: $(date)"
