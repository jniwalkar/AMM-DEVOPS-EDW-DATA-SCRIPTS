#!/bin/bash
# Script: setup_monthly_mysql_dump.sh
# Setup cron job for monthly MySQL dump collection
# Author: Infrastructure Team

# Configuration
SCRIPT_PATH="/opt/scripts/bulk_mysql_dump_to_s3.sh"
MONTHLY_RUN_DATE=1  # Run on 1st of each month at 9 AM
CRON_USER="root"  # User to run the cron job
CRON_HOUR=9  # Run at 9 AM
CRON_MINUTE=0  # At exactly 9:00 AM

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to create cron job
setup_cron_job() {
    echo -e "${BLUE}Setting up monthly MySQL dump cron job...${NC}"
    
    # Create cron job entry
    local cron_entry="${CRON_MINUTE} ${CRON_HOUR} ${MONTHLY_RUN_DATE} * * ${SCRIPT_PATH} >> /var/log/mysql_dump_monthly.log 2>&1"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        echo -e "${YELLOW}Cron job already exists. Removing old entry...${NC}"
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    fi
    
    # Add new cron job
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Cron job created successfully${NC}"
        echo -e "${GREEN}  Schedule: ${MONTHLY_RUN_DATE}th of every month at ${CRON_HOUR}:$(printf '%02d' $CRON_MINUTE) AM${NC}"
        echo -e "${GREEN}  Log file: /var/log/mysql_dump_monthly.log${NC}"
    else
        echo -e "${RED}✗ Failed to create cron job${NC}"
        return 1
    fi
}

# Function to create log rotation for monthly dumps
setup_log_rotation() {
    echo -e "${BLUE}Setting up log rotation...${NC}"
    
    cat > /etc/logrotate.d/mysql_dump_monthly << 'EOF'
/var/log/mysql_dump_monthly.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}

/var/log/mysql_dump_collection_*.log {
    monthly
    rotate 6
    compress
    delaycompress
    missingok
    notifempty
    maxage 180
    size 100M
}
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Log rotation configured${NC}"
    else
        echo -e "${RED}✗ Failed to configure log rotation${NC}"
    fi
}

# Function to create monitoring script
create_monitoring_script() {
    echo -e "${BLUE}Creating monitoring script...${NC}"
    
    cat > /opt/scripts/check_monthly_dump_status.sh << 'EOF'
#!/bin/bash
# MySQL Dump Status Monitoring Script

BUCKET="mysql-dumps-for-edw-team"
CURRENT_MONTH_YEAR=$(date +%m-%Y)
ALERT_EMAIL="admin@company.com"  # Change this to your email

# Check if current month's dump exists
if aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ >/dev/null 2>&1; then
    file_count=$(aws s3 ls s3://$BUCKET/$CURRENT_MONTH_YEAR/ | wc -l)
    echo "✓ Current month dumps found: $file_count files in $CURRENT_MONTH_YEAR"
    
    if [ $file_count -ge 20 ]; then
        echo "✓ All 20 server dumps appear to be present"
    else
        echo "⚠ Warning: Only $file_count dumps found, expected 20"
        echo "Missing dumps for month: $CURRENT_MONTH_YEAR" | mail -s "MySQL Dump Alert - Missing Files" $ALERT_EMAIL
    fi
else
    echo "✗ No dumps found for current month: $CURRENT_MONTH_YEAR"
    echo "No MySQL dumps found for current month: $CURRENT_MONTH_YEAR" | mail -s "MySQL Dump Alert - No Data" $ALERT_EMAIL
fi

# List recent dump directories
echo ""
echo "Recent dump directories in S3:"
aws s3 ls s3://$BUCKET/ | grep "PRE.*-.*/" | tail -6

# Check disk space on jumphost
echo ""
echo "Jumphost disk space:"
df -h /tmp
EOF

    chmod +x /opt/scripts/check_monthly_dump_status.sh
    
    echo -e "${GREEN}✓ Monitoring script created: /opt/scripts/check_monthly_dump_status.sh${NC}"
}

# Function to create email notification template
create_notification_template() {
    echo -e "${BLUE}Creating notification templates...${NC}"
    
    # Success notification template
    cat > /opt/scripts/notify_dump_success.sh << 'EOF'
#!/bin/bash
# Success notification script

MONTH_YEAR=$(date +%m-%Y)
SERVER_COUNT=$1
BUCKET="mysql-dumps-for-edw-team"
RECIPIENT="admin@company.com"  # Change this

cat << EMAIL | mail -s "MySQL Dumps Completed Successfully - $MONTH_YEAR" $RECIPIENT
MySQL Dump Collection Report
============================

Date: $(date)
Month: $MONTH_YEAR
Status: SUCCESS
Servers Processed: $SERVER_COUNT/20

S3 Location: s3://$BUCKET/$MONTH_YEAR/

All MySQL dumps have been successfully collected and uploaded to S3.
The EDW team can now access the data for processing.

File Details:
$(aws s3 ls s3://$BUCKET/$MONTH_YEAR/ --human-readable --summarize)

Next scheduled run: $(date -d "next month" +%B) 15th, $(date -d "next month" +%Y)

MySQL Dump Collection System
EMAIL
EOF

    # Failure notification template
    cat > /opt/scripts/notify_dump_failure.sh << 'EOF'
#!/bin/bash
# Failure notification script

MONTH_YEAR=$(date +%m-%Y)
FAILED_SERVERS="$1"
RECIPIENT="admin@company.com"  # Change this

cat << EMAIL | mail -s "MySQL Dumps Failed - $MONTH_YEAR" $RECIPIENT
MySQL Dump Collection Alert
===========================

Date: $(date)
Month: $MONTH_YEAR
Status: FAILURE/PARTIAL

Failed Servers: $FAILED_SERVERS

Please check the log files and re-run for failed servers:
/var/log/mysql_dump_monthly.log
/var/log/mysql_dump_collection_*.log

Manual re-run command:
/opt/scripts/bulk_mysql_dump_to_s3.sh --force

MySQL Dump Collection System
EMAIL
EOF

    chmod +x /opt/scripts/notify_dump_success.sh
    chmod +x /opt/scripts/notify_dump_failure.sh
    
    echo -e "${GREEN}✓ Notification scripts created${NC}"
}

# Function to show current status
show_status() {
    echo -e "${BLUE}=== Current MySQL Dump Setup Status ===${NC}"
    
    echo -e "\n${YELLOW}Cron Jobs:${NC}"
    crontab -l | grep -E "(mysql_dump|bulk_mysql)" || echo "No MySQL dump cron jobs found"
    
    echo -e "\n${YELLOW}Script Location:${NC}"
    if [ -f "$SCRIPT_PATH" ]; then
        echo -e "${GREEN}✓ Main script found: $SCRIPT_PATH${NC}"
        ls -la "$SCRIPT_PATH"
    else
        echo -e "${RED}✗ Main script not found: $SCRIPT_PATH${NC}"
    fi
    
    echo -e "\n${YELLOW}Log Files:${NC}"
    ls -la /var/log/mysql_dump* 2>/dev/null || echo "No log files found"
    
    echo -e "\n${YELLOW}S3 Bucket Status:${NC}"
    if aws s3 ls s3://mysql-dumps-for-edw-team/ >/dev/null 2>&1; then
        echo -e "${GREEN}✓ S3 bucket accessible${NC}"
        echo "Recent directories:"
        aws s3 ls s3://mysql-dumps-for-edw-team/ | grep "PRE.*-.*/" | tail -3
    else
        echo -e "${RED}✗ S3 bucket not accessible${NC}"
    fi
    
    echo -e "\n${YELLOW}Next Scheduled Run:${NC}"
    local next_run=$(date -d "$(date +%Y-%m)-${MONTHLY_RUN_DATE}" +%Y-%m-%d 2>/dev/null)
    if [ $(date +%d | sed 's/^0//') -gt $MONTHLY_RUN_DATE ]; then
        next_run=$(date -d "next month" +%Y-%m)-${MONTHLY_RUN_DATE}
    fi
    echo "Date: $next_run at ${CRON_HOUR}:$(printf '%02d' $CRON_MINUTE) AM"
}

# Function to remove setup
remove_setup() {
    echo -e "${RED}Removing MySQL dump setup...${NC}"
    
    # Remove cron job
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    echo -e "${GREEN}✓ Cron job removed${NC}"
    
    # Remove logrotate config
    rm -f /etc/logrotate.d/mysql_dump_monthly
    echo -e "${GREEN}✓ Log rotation config removed${NC}"
    
    echo -e "${YELLOW}Note: Scripts and logs are preserved${NC}"
}

# Main function
main() {
    case "${1:-}" in
        install|setup)
            echo -e "${GREEN}Setting up monthly MySQL dump system...${NC}"
            
            # Check if main script exists
            if [ ! -f "$SCRIPT_PATH" ]; then
                echo -e "${RED}Error: Main script not found at $SCRIPT_PATH${NC}"
                echo -e "${YELLOW}Please ensure the main dump script is installed first${NC}"
                exit 1
            fi
            
            # Create directories
            mkdir -p /opt/scripts
            mkdir -p /var/log
            
            # Setup components
            setup_cron_job
            setup_log_rotation
            create_monitoring_script
            create_notification_template
            
            echo -e "${GREEN}=== Setup Complete ===${NC}"
            echo -e "${GREEN}Monthly MySQL dumps will run on the ${MONTHLY_RUN_DATE}th of each month at ${CRON_HOUR}:$(printf '%02d' $CRON_MINUTE) AM${NC}"
            ;;
            
        status)
            show_status
            ;;
            
        remove|uninstall)
            remove_setup
            ;;
            
        test)
            echo -e "${BLUE}Testing monthly dump system...${NC}"
            $SCRIPT_PATH --test
            ;;
            
        *)
            echo "Usage: $0 {install|status|remove|test}"
            echo ""
            echo "Commands:"
            echo "  install  - Setup monthly dump system with cron job"
            echo "  status   - Show current setup status"
            echo "  remove   - Remove cron job and cleanup"
            echo "  test     - Test SSH connections"
            echo ""
            echo "Configuration:"
            echo "  Run Date: ${MONTHLY_RUN_DATE}th of each month"
            echo "  Run Time: ${CRON_HOUR}:$(printf '%02d' $CRON_MINUTE) AM"
            echo "  Script: $SCRIPT_PATH"
            exit 1
            ;;
    esac
}

main "$@"