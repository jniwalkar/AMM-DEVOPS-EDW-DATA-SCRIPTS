AMM MySQL Data Collection System - Complete Setup Guide
This system automates the collection of MySQL query results from multiple AMM servers, converts them to Excel format, and uploads to both AWS S3 and SFTP destinations.

Table of Contents
Overview
Architecture
Prerequisites
Step 1: Jumphost Environment Setup
Step 2: AWS Configuration
Step 3: SSH Key Setup
Step 4: Deploy Scripts
Step 5: Python Virtual Environment
Step 6: Configuration
Step 7: Testing
Step 8: Automation Setup
Troubleshooting
Maintenance
Overview
What This System Does
Connects to multiple AMM servers via SSH (port 2222)
Executes three SQL queries to extract data:
Group Hierarchy Path
Gateway Count By Group
User List With Groups
Converts TSV results to Excel format with multiple sheets
Uploads to AWS S3 and SFTP server
Sends email summary with success/failure status
Cleans up old data automatically (3-month retention)
Key Features
✅ Automated monthly execution on the 15th
✅ Handles large datasets (splits Excel sheets at 1M+ rows)
✅ Real-time progress monitoring
✅ Comprehensive error handling
✅ Email notifications with detailed summaries
✅ Dual upload (S3 + SFTP)
✅ Python virtual environment for isolated dependencies
✅ No changes required on production AMM servers
Architecture
┌─────────────┐
│  Jumphost   │
│  (Executor) │
└──────┬──────┘
       │
       ├─ SSH (Port 2222) ──► AMM01, AMM02, ..., AMM89
       │                       (Execute MySQL queries)
       │
       ├─ Python Script ─────► Convert TSV to Excel
       │                       (Handle large datasets)
       │
       ├─ AWS S3 ───────────► Upload Excel files
       │                       (Long-term storage)
       │
       ├─ SFTP ─────────────► Upload to external FTP
       │                       (EDW team access)
       │
       └─ Email ────────────► Send summary report
                               (Success/Failure status)
Prerequisites
Required on Jumphost
OS: Linux (RHEL/CentOS/Amazon Linux)
User: Non-root user with sudo privileges (e.g., sahire)
Network: Access to AMM servers on port 2222
Storage: At least 5GB free space for temporary files
Required on AMM Servers (No Changes Needed)
MySQL: Database running with inmotion database
SSH: Enabled on port 2222
User: imtadmin with sudo privileges
Password File: /mnt/amm_data/opt/tomcat/webapps/inmotion/config/amm_secure_data
Required Credentials
AWS IAM credentials with S3 access
SFTP server credentials
Email server access (sendmail configured)
Step 1: Jumphost Environment Setup
1.1 Create Directory Structure
bash
# Create base directory
mkdir -p /home/sahire/edw-data-scripts/logs

# Navigate to directory
cd /home/sahire/edw-data-scripts/

# Verify structure
ls -la
Expected output:

drwxr-xr-x. 3 sahire sahire 4096 Dec 17 10:00 .
drwx------. 8 sahire sahire 4096 Dec 17 09:55 ..
drwxr-xr-x. 2 sahire sahire 4096 Dec 17 10:00 logs
1.2 Install Required System Packages
bash
# Update system (optional but recommended)
sudo yum update -y

# Install Python 3
sudo yum install python3 python3-pip -y

# Install AWS CLI
sudo yum install awscli -y

# Install lftp (for SFTP uploads)
sudo yum install lftp -y

# Install coreutils (includes stdbuf for unbuffered output)
sudo yum install coreutils -y

# Verify installations
python3 --version       # Should show: Python 3.6+
aws --version          # Should show: aws-cli/1.x or 2.x
lftp --version         # Should show: LFTP version
which stdbuf           # Should show: /usr/bin/stdbuf
Expected versions:

Python 3.6.8 or higher
aws-cli/1.18.147 or higher
LFTP | Version 4.4.8 or later
Step 2: AWS Configuration
2.1 Configure AWS CLI
bash
# Configure AWS credentials
aws configure

# You'll be prompted for:
# AWS Access Key ID: [Your Access Key]
# AWS Secret Access Key: [Your Secret Key]
# Default region name: us-west-2
# Default output format: json
2.2 Verify AWS Credentials
bash
# Test AWS CLI access
aws sts get-caller-identity

# Expected output:
# {
#     "UserId": "AIDAXXXXXXXXXX",
#     "Account": "123456789012",
#     "Arn": "arn:aws:iam::123456789012:user/username"
# }
2.3 Create S3 Bucket
bash
# Create S3 bucket
aws s3 mb s3://mysql-dumps-for-edw-team --region us-west-2

# Verify bucket creation
aws s3 ls | grep mysql-dumps-for-edw-team
Expected output:

2025-12-17 10:00:00 mysql-dumps-for-edw-team
2.4 Set S3 Lifecycle Policy (Optional)
bash
# Create lifecycle policy file
cat > /tmp/s3-lifecycle.json << 'EOF'
{
  "Rules": [
    {
      "ID": "DeleteOldDumps",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "Transitions": [
        {
          "Days": 30,
          "StorageClass": "STANDARD_IA"
        }
      ],
      "Expiration": {
        "Days": 90
      }
    }
  ]
}
EOF

# Apply lifecycle policy
aws s3api put-bucket-lifecycle-configuration \
  --bucket mysql-dumps-for-edw-team \
  --lifecycle-configuration file:///tmp/s3-lifecycle.json

# Verify policy
aws s3api get-bucket-lifecycle-configuration \
  --bucket mysql-dumps-for-edw-team
2.5 Test S3 Access
bash
# Create test file
echo "test" > /tmp/s3_test.txt

# Upload test file
aws s3 cp /tmp/s3_test.txt s3://mysql-dumps-for-edw-team/test.txt

# List bucket contents
aws s3 ls s3://mysql-dumps-for-edw-team/

# Download test file
aws s3 cp s3://mysql-dumps-for-edw-team/test.txt /tmp/s3_test_download.txt

# Verify
cat /tmp/s3_test_download.txt

# Cleanup
aws s3 rm s3://mysql-dumps-for-edw-team/test.txt
rm -f /tmp/s3_test.txt /tmp/s3_test_download.txt
Step 3: SSH Key Setup
3.1 Check for Existing SSH Key
bash
# Check if SSH key already exists
ls -la ~/.ssh/id_ed25519

# If exists, skip to 3.3
# If not exists, continue to 3.2
3.2 Generate New SSH Key
bash
# Generate Ed25519 SSH key (more secure than RSA)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "jumphost-to-amm" -N ""

# Set proper permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Verify key creation
ls -la ~/.ssh/id_ed25519*
Expected output:

-rw------- 1 sahire sahire  464 Dec 17 10:05 /home/sahire/.ssh/id_ed25519
-rw-r--r-- 1 sahire sahire  104 Dec 17 10:05 /home/sahire/.ssh/id_ed25519.pub
3.3 Copy SSH Key to All AMM Servers
Important: You'll need to enter the password for imtadmin user on each server.

bash
# Copy SSH key to each AMM server
# Replace SERVER_IP with actual IP addresses

# AMM01
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 imtadmin@amm01.airlink.com

# AMM02
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 imtadmin@amm02.airlink.com

# AMM03
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 imtadmin@amm03.airlink.com

# ... Continue for all servers (AMM01-AMM11, AMM50, AMM52, AMM81-AMM90)
Batch Copy Script (saves time for multiple servers):

bash
# Create a file with all server hostnames
cat > /tmp/amm_servers.txt << 'EOF'
amm01.airlink.com
amm02.airlink.com
amm03.airlink.com
amm04.airlink.com
amm05.airlink.com
amm06.airlink.com
amm07.airlink.com
amm08.airlink.com
amm09.airlink.com
amm10.airlink.com
amm11.airlink.com
amm50.airlink.com
amm52.airlink.com
amm81.airlink.com
amm82.airlink.com
amm84.airlink.com
amm86.airlink.com
amm87.airlink.com
amm88.airlink.com
amm89.airlink.com
amm90.airlink.com
EOF

# Copy key to all servers
while read server; do
    echo "Copying key to $server..."
    ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 imtadmin@$server
done < /tmp/amm_servers.txt
3.4 Test SSH Connections
bash
# Test SSH connection to each server (should not prompt for password)
ssh -i ~/.ssh/id_ed25519 -p 2222 imtadmin@amm01.airlink.com "echo 'SSH OK'"

# Test with all servers
while read server; do
    echo -n "Testing $server... "
    if ssh -i ~/.ssh/id_ed25519 -p 2222 -o ConnectTimeout=5 imtadmin@$server "echo OK" 2>/dev/null; then
        echo "✓ Success"
    else
        echo "✗ Failed"
    fi
done < /tmp/amm_servers.txt
Expected output:

Testing amm01.airlink.com... ✓ Success
Testing amm02.airlink.com... ✓ Success
Testing amm03.airlink.com... ✓ Success
...
Step 4: Deploy Scripts
4.1 Create Scripts Directory
bash
cd /home/sahire/edw-data-scripts/
4.2 Create Shell Script
Create bulk_mysql_dump_to_sftp.sh:

bash
nano bulk_mysql_dump_to_sftp.sh
Copy the entire shell script content from the artifact and paste it. Save and exit (Ctrl+X, Y, Enter).

4.3 Create Python Script
Create create_excel_from_tsv.py:

bash
nano create_excel_from_tsv.py
Copy the entire Python script content from the artifact and paste it. Save and exit (Ctrl+X, Y, Enter).

4.4 Set Permissions
bash
# Make scripts executable
chmod +x bulk_mysql_dump_to_sftp.sh
chmod +x create_excel_from_tsv.py

# Verify permissions
ls -la /home/sahire/edw-data-scripts/*.{sh,py}
Expected output:

-rwxr-xr-x 1 sahire sahire 45678 Dec 17 10:10 bulk_mysql_dump_to_sftp.sh
-rwxr-xr-x 1 sahire sahire 23456 Dec 17 10:10 create_excel_from_tsv.py
Step 5: Python Virtual Environment
5.1 Automatic Setup (Recommended)
The script will automatically create the virtual environment on first run:

bash
# The script will:
# 1. Check if venv exists at /home/sahire/edw-data-scripts/venv
# 2. Create venv if not found
# 3. Install openpyxl library
# 4. Verify installation
5.2 Manual Setup (Optional)
If you prefer to create the virtual environment manually:

bash
# Navigate to scripts directory
cd /home/sahire/edw-data-scripts/

# Create virtual environment
python3 -m venv venv

# Verify venv creation
ls -la venv/

# Activate virtual environment
source venv/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install openpyxl
pip install openpyxl

# Verify installation
python -c "import openpyxl; print('openpyxl version:', openpyxl.__version__)"

# Deactivate
deactivate
Expected output:

openpyxl version: 3.1.2
5.3 Verify Virtual Environment
bash
# Check venv structure
ls -la /home/sahire/edw-data-scripts/venv/

# Test Python in venv
/home/sahire/edw-data-scripts/venv/bin/python3 --version

# Test openpyxl in venv
/home/sahire/edw-data-scripts/venv/bin/python3 -c "import openpyxl; print('OK')"
Step 6: Configuration
6.1 Update Shell Script Configuration
Edit bulk_mysql_dump_to_sftp.sh:

bash
nano /home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh
Update these variables (around lines 5-30):

bash
# S3 Configuration
BUCKET="mysql-dumps-for-edw-team"

# SSH Configuration
SSH_USER="imtadmin"
SSH_KEY="/home/sahire/.ssh/id_ed25519"
SSH_PORT="2222"

# MySQL Configuration
MYSQL_USER="root"
MYSQL_DATABASE="inmotion"

# Email Configuration
SUMMARY_EMAIL="your-email@company.com"  # ← Update this

# SFTP Configuration
SFTP_HOST="ftp.semtech.com"
SFTP_USER="SW_AMM_UAT"
SFTP_PASSWORD="YOUR_SFTP_PASSWORD"  # ← Update this
SFTP_REMOTE_DIR="/amm-mysql-dumps"

# Script Paths
PYTHON_SCRIPT="/home/sahire/edw-data-scripts/create_excel_from_tsv.py"
VENV_DIR="/home/sahire/edw-data-scripts/venv"

# Schedule Configuration
MONTHLY_RUN_DATE=15
DATA_RETENTION_MONTHS=3
6.2 Update Server List
In the same file, update the SERVERS array (around line 40):

bash
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
    ["AMM50"]="amm50.airlink.com"
    ["AMM52"]="amm52.airlink.com"
    ["AMM81"]="amm81.airlink.com"
    ["AMM82"]="amm82.airlink.com"
    ["AMM84"]="amm84.airlink.com"
    ["AMM86"]="amm86.airlink.com"
    ["AMM87"]="amm87.airlink.com"
    ["AMM88"]="amm88.airlink.com"
    ["AMM89"]="amm89.airlink.com"
    ["AMM90"]="amm90.airlink.com"
)
Save and exit (Ctrl+X, Y, Enter).

6.3 Verify Configuration
bash
# Check script syntax
bash -n /home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh

# If no output, syntax is OK
# If errors appear, review and fix them
Step 7: Testing
7.1 Test Script Help
bash
cd /home/sahire/edw-data-scripts/

# View help
./bulk_mysql_dump_to_sftp.sh --help
Expected output:

Usage: ./bulk_mysql_dump_to_sftp.sh [options]

OPTIONS:
  -h, --help      Help
  -t, --test      Test SSH
  -s, --server    Single server
  -f, --force     Force run
  -c, --cleanup   Cleanup only
  -l, --list      List servers
7.2 List Configured Servers
bash
./bulk_mysql_dump_to_sftp.sh --list
Expected output:

  AMM01 -> amm01.airlink.com
  AMM02 -> amm02.airlink.com
  AMM03 -> amm03.airlink.com
  ...
7.3 Test SSH Connections
bash
./bulk_mysql_dump_to_sftp.sh --test
Expected output:

2025-12-17 10:15:00 - Testing SSH...
2025-12-17 10:15:00 - Testing SSH: AMM01 (amm01.airlink.com)
2025-12-17 10:15:01 - SSH successful
2025-12-17 10:15:01 - Testing SSH: AMM02 (amm02.airlink.com)
2025-12-17 10:15:02 - SSH successful
...
2025-12-17 10:15:30 - Results: 21/21 OK
7.4 Test Single Server Execution
bash
# Test with one server first
./bulk_mysql_dump_to_sftp.sh --server AMM01 --force
This will:

Connect to AMM01
Execute queries
Download results
Convert to Excel
Upload to S3 and SFTP
Send email summary
Monitor the output for any errors.

7.5 Verify Output
bash
# Check log file
tail -100 /home/sahire/edw-data-scripts/logs/mysql_dump_collection_*.log

# Check S3 upload
aws s3 ls s3://mysql-dumps-for-edw-team/$(date +%b-%Y)/

# Check SFTP upload (if applicable)
lftp -u "${SFTP_USER},${SFTP_PASSWORD}" sftp://${SFTP_HOST} << EOF
ls ${SFTP_REMOTE_DIR}
bye
EOF
7.6 Test All Servers (Dry Run)
Once single server test passes:

bash
# Run for all servers (with force flag)
./bulk_mysql_dump_to_sftp.sh --force
Step 8: Automation Setup
8.1 Configure Cron Job
bash
# Edit crontab
crontab -e
Add the following line to run on the 15th of every month at 2 AM:

bash
# AMM MySQL Data Collection - Runs monthly on the 15th at 2 AM
0 2 15 * * /home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh >> /home/sahire/edw-data-scripts/logs/cron_output.log 2>&1
Alternative: Run weekly for testing:

bash
# Run every Sunday at 2 AM
0 2 * * 0 /home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh --force >> /home/sahire/edw-data-scripts/logs/cron_output.log 2>&1
8.2 Verify Cron Job
bash
# List cron jobs
crontab -l

# Check cron service status
systemctl status crond

# View cron logs
tail -50 /var/log/cron
8.3 Test Cron Execution
bash
# Manually trigger the cron command to test
/home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh --force >> /home/sahire/edw-data-scripts/logs/cron_output.log 2>&1

# Check output
cat /home/sahire/edw-data-scripts/logs/cron_output.log
Troubleshooting
Common Issues and Solutions
Issue 1: SSH Connection Failures
Symptoms:

SSH connection to AMM01 failed
Solutions:

bash
# 1. Verify SSH key permissions
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# 2. Test SSH manually
ssh -vvv -i ~/.ssh/id_ed25519 -p 2222 imtadmin@amm01.airlink.com

# 3. Check if key is in authorized_keys on remote server
ssh -i ~/.ssh/id_ed25519 -p 2222 imtadmin@amm01.airlink.com "cat ~/.ssh/authorized_keys"

# 4. Re-copy SSH key
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 imtadmin@amm01.airlink.com
Issue 2: Python Module Not Found
Symptoms:

ModuleNotFoundError: No module named 'openpyxl'
Solutions:

bash
# 1. Check if venv exists
ls -la /home/sahire/edw-data-scripts/venv/

# 2. Reinstall openpyxl in venv
/home/sahire/edw-data-scripts/venv/bin/pip install --upgrade openpyxl

# 3. Verify installation
/home/sahire/edw-data-scripts/venv/bin/python3 -c "import openpyxl; print('OK')"

# 4. Delete and recreate venv
rm -rf /home/sahire/edw-data-scripts/venv
python3 -m venv /home/sahire/edw-data-scripts/venv
/home/sahire/edw-data-scripts/venv/bin/pip install openpyxl
Issue 3: AWS S3 Access Denied
Symptoms:

ERROR: Cannot access S3 bucket: mysql-dumps-for-edw-team
Solutions:

bash
# 1. Verify AWS credentials
aws sts get-caller-identity

# 2. Check S3 bucket permissions
aws s3api get-bucket-acl --bucket mysql-dumps-for-edw-team

# 3. Test bucket access
aws s3 ls s3://mysql-dumps-for-edw-team/

# 4. Reconfigure AWS CLI
aws configure
Issue 4: MySQL Connection Timeout
Symptoms:

ERROR: MySQL connection failed after 5 attempts
Solutions:

bash
# 1. SSH to the server and test MySQL manually
ssh -i ~/.ssh/id_ed25519 -p 2222 imtadmin@amm01.airlink.com

# 2. On the remote server, test MySQL
sudo mysql -u root inmotion -e "SELECT 1"

# 3. Check if password file exists
sudo cat /mnt/amm_data/opt/tomcat/webapps/inmotion/config/amm_secure_data

# 4. Check MySQL service status
sudo systemctl status mysql
Issue 5: Excel File Not Created
Symptoms:

Excel failed
Solutions:

bash
# 1. Check Python script syntax
python3 -m py_compile /home/sahire/edw-data-scripts/create_excel_from_tsv.py

# 2. Test Python script manually
/home/sahire/edw-data-scripts/venv/bin/python3 \
  /home/sahire/edw-data-scripts/create_excel_from_tsv.py \
  /tmp/test_tsv \
  /tmp/test_output.xlsx \
  AMM01

# 3. Check for TSV files
ls -la /tmp/tsv_AMM*

# 4. Check disk space
df -h /tmp
Issue 6: SFTP Upload Failed
Symptoms:

SFTP upload failed
Solutions:

bash
# 1. Test SFTP connection manually
lftp -u "${SFTP_USER},${SFTP_PASSWORD}" sftp://${SFTP_HOST}

# 2. Check SFTP credentials in script
grep -A5 "SFTP Configuration" /home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh

# 3. Test file upload manually
echo "test" > /tmp/test_sftp.txt
lftp -u "SW_AMM_UAT,PASSWORD" sftp://ftp.semtech.com << EOF
cd /amm-mysql-dumps
put /tmp/test_sftp.txt
bye
EOF

# 4. Check if lftp is installed
which lftp
Issue 7: Email Not Received
Symptoms:

Email failed to send summary
Solutions:

bash
# 1. Check if sendmail is installed and running
which sendmail
systemctl status sendmail

# 2. Test sendmail manually
echo "Test email body" | sendmail -v your-email@company.com

# 3. Check mail logs
tail -50 /var/log/maillog

# 4. Verify email configuration in script
grep "SUMMARY_EMAIL" /home/sahire/edw-data-scripts/bulk_mysql_dump_to_sftp.sh
Issue 8: No Data Available in Excel
Symptoms:

Excel shows "No Data Available" but queries should return data
Solutions:

bash
# 1. Check if TSV files have data
ls -lh /tmp/tsv_AMM01_*/*.tsv

# 2. View TSV file contents
head -20 /tmp/tsv_AMM01_*/User_List_With_Groups.tsv

# 3. Check MySQL query results on remote server
ssh -i ~/.ssh/id_ed25519 -p 2222 imtadmin@amm01.airlink.com
sudo mysql -u root inmotion -e "SELECT COUNT(*) FROM im_user"

# 4. Review remote script execution logs
cat /home/sahire/edw-data-scripts/logs/mysql_dump_collection_*.log | grep "NO_DATA"
Maintenance
Daily Checks
bash
# Check disk space
df -h /home/sahire/edw-data-scripts/

# Check recent logs
tail -100 /home/sahire/edw-data-scripts/logs/mysql_dump_collection_$(date +%Y%m%d)*.log

# Check S3 uploads
aws s3 ls s3://mysql-dumps-for-edw-team/$(date +%b-%Y)/ | tail -20
Weekly Checks
bash
# Review all logs from past week
ls -lt /home/sahire/edw-data-scripts/logs/ | head -20

# Check S3 storage usage
aws s3 ls s3://mysql-dumps-for-edw-team/ --recursive --human-readable --summarize

# Verify cron job is scheduled
crontab -l | grep bulk_mysql
Monthly Tasks
bash
# Verify data retention cleanup
aws s3 ls s3://mysql-dumps-for-edw-team/ | wc -l

# Update server list if needed
./bulk_mysql_dump_to_sftp.sh --list

# Test SSH connections
./bulk_mysql_dump_to_sftp.sh --test

# Review email summaries
# Check your email for "AMM MySQL DB Collection Summary"
Log Rotation
bash
# Create logrotate config
sudo nano /etc/logrotate.d/amm-mysql-dumps

# Add this content:
/home/sahire/edw-data-scripts/logs/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 0644 sahire sahire
}

# Test logrotate
sudo logrotate -d /etc/logrotate.d/amm-mysql-dumps
Clean Up Old Files
bash
# Clean up logs older than 90 days
find /home/sahire/edw-data-scripts/logs/ -name "*.log" -mtime +90 -delete

# Clean up temporary files
rm -f /tmp/mysql_results_*.tar.gz
rm -rf /tmp/tsv_AMM*
rm -f /tmp/remote_out_*.log
Update Scripts
bash
# Backup current scripts before updating
cp bulk_mysql_dump_to_sftp.sh bulk_mysql_dump_to_sftp.sh.backup.$(date +%Y%m%d)
cp create_excel_from_tsv.py create_excel_from_tsv.py.backup.$(date +%Y%m%d)

# Update scripts (after testing in dev environment)
# ... make changes ...

# Test updated scripts
./bulk_mysql_dump_to_sftp.sh --server AMM01 --force

# If successful, remove old backups
find . -name "*.backup.*" -mtime +30 -delete
Directory Structure Reference
/home/sahire/edw-data-scripts/
├── bulk_mysql_dump_to_sftp.sh          # Main shell script
├── create_excel_from_tsv.py          # Python Excel converter
├── venv/                             # Python virtual environment
│   ├── bin/
│   │   ├── python3                   # Python interpreter
│   │   ├── pip                       # Package installer
│   │   └── activate                  # Activation script
│   └── lib/
│       └── python3.x/
│           └── site-packages/
│               └── openpyxl/         # Excel library
└── logs/                             # Log files
    ├── mysql_dump_collection_YYYYMMDD_HHMMSS.log
    ├── summary_YYYYMMDD_HHMMSS.txt
    └── cron_output.log
Support and Contact
For issues or questions:

Check logs first: /home/sahire/edw-data-scripts/logs/
Review troubleshooting section above
Contact: DevOps Team / System Administrator
Version History
v1.0 (2025-12-17): Initial setup with S3 and SFTP support
v1.1 (2025-12-17): Added "No Data Available" handling for empty queries
v1.2 (2025-12-17): Added real-time progress monitoring with unbuffered output
License
Internal use only - Property of [Your Company Name]

End of Setup Guide

