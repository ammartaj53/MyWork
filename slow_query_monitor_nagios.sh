#!/bin/bash

maindir=/home/nagios

if [ ! -s $maindir/Warning_Query.txt ] && [ ! -s $maindir/Critical_Query.txt ]; then

echo "No slow queries on the server";

exit 0;

elif [ -s $maindir/Warning_Query.txt ] && [ ! -s $maindir/Critical_Query.txt ]; then

echo `cat $maindir/Warning_Query.txt`

exit 1;

elif [ -s $maindir/Critical_Query.txt ]; then

echo `cat $maindir/Critical_Query.txt`
printf '\n'
echo `cat $maindir/Warning_Query.txt`

exit 2;

fi
