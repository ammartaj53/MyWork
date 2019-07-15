#!/bin/bash

maindir=/home/nagios

TO=ammar.taj@volocommerce.com,Vijaya.Ghalige@volocommerce.com,Anil.Kumar@volocommerce.com,Nick.Anderson@volocommerce.com,Paul.Dicken@volocommerce.com,Gary.Wright@volocommerce.com,Jason.deVine@volocommerce.com

>Final_report.txt

echo "SELECT USER,DB,TIME FROM INFORMATION_SCHEMA.PROCESSLIST WHERE COMMAND!='Sleep' and USER NOT LIKE 'repl%' and USER NOT IN ('system user') and TIME>300 and TIME<600 ORDER BY TIME DESC"| mysql -A > $maindir/Warning_Query.txt

chmod 777 $maindir/Warning_Query.txt

sed -i "s/$/\\\n/" $maindir/Warning_Query.txt

echo "SELECT USER,DB,TIME FROM INFORMATION_SCHEMA.PROCESSLIST WHERE COMMAND!='Sleep' and USER NOT LIKE 'repl%' and USER NOT IN ('system user') and TIME>600 ORDER BY TIME DESC"| mysql -A > $maindir/Critical_Query.txt

chmod 777 $maindir/Critical_Query.txt

sed -i "s/$/\\\n/" $maindir/Critical_Query.txt
