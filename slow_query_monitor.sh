#!/bin/bash

maindir=/home/nagios

TO="Your Email List"

>Final_report.txt

echo "SELECT USER,DB,TIME FROM INFORMATION_SCHEMA.PROCESSLIST WHERE COMMAND!='Sleep' and USER NOT LIKE 'repl%' and USER NOT IN ('system user') and TIME>300 and TIME<600 ORDER BY TIME DESC"| mysql -A > $maindir/Warning_Query.txt

chmod 777 $maindir/Warning_Query.txt

sed -i "s/$/\\\n/" $maindir/Warning_Query.txt

echo "SELECT USER,DB,TIME FROM INFORMATION_SCHEMA.PROCESSLIST WHERE COMMAND!='Sleep' and USER NOT LIKE 'repl%' and USER NOT IN ('system user') and TIME>600 ORDER BY TIME DESC"| mysql -A > $maindir/Critical_Query.txt

chmod 777 $maindir/Critical_Query.txt

sed -i "s/$/\\\n/" $maindir/Critical_Query.txt
