#!/bin/bash
#
#
# Desc: The purpose of this script is to provide an application/server type agnostic backup solution, but with consideration for sensitive 
# sitatuations where e.g. read locking cannot be tolerated.
# Contains parts of tajbackup_database and incorporates new AWS S3 backups upload.
#
#

#set -o errexit  # exit on error
#set -o nounset  # exit on unset variables used

SCRIPT="`basename ${0} | cut -d. -f1`"
tajSUBDOMAIN=`hostname -s`

# main body of routines
do_master_backup() {
	# master backup
	# only perform if forced
	dohk
	chkdisk
	dobackup
#	s3upload (filename format)
}

do_slave_backup() {
	# slave backup (locked tables/read only etc)
	dohk
	chkdisk
	dobackupslave
#	s3upload (filename format)
}

do_nonrepl_backup() {
	# other backup (safe/non-locking/conservative etc)
	dohk
	chkdisk
	dobackup
#	s3upload
	logtrim
}

chkret()
{
	retcode=$?
	tstamp=`date +%H:%M:%S`

	# log
	if [ $2 == log ]; then
		echo "$tstamp - $SCRIPT - $1"
		return
	fi

	# force stop
	if [ $2 == stop ]; then
		echo "$tstamp - $SCRIPT - $1"
		rm -f ${tajLOGDIR}/${SCRIPT}.active
		exit 1
	fi

	# other, unknown failure - exit
	if [ $retcode != 0 ]; then 
		echo "$tstamp - $SCRIPT - $1"
		rm -f ${tajLOGDIR}/${SCRIPT}.active
		exit 1
	fi
	return
}

initparams() {
	# set default parameters here
	# do not override here, set in config file
	tajFORCESLAVEBACKUP=0
	tajFORCEMASTERBACKUP=0
	tajAPPTYPE=
	tajBACKUPRETENTION=7
	tajDBLOGTRIM=no
	tajTRIMDAYS=3
	tajEXCLUDETABS=()
	tajEXTRADBS=()
}

chkparams() {
	# load global parameters
	. ~/bin/tajbackup_complete.cfg

	# substitute socket and port if overridden
	mysqlSOCKET="${mySOCKET:-$mysqlSOCKET}"
	tajSUBDOMAIN="${mySUBDOMAIN:-$tajSUBDOMAIN}"


	chkret "Call to tajParams failed" fail

	# Check all required parameters are available
	# dependent upon server/backup type

	# Check some more parameters

	# all
	if [ -z "${tajDBBCKDIR}" ]; then
		chkret "Environment var tajDBBCKDIR is undefined" stop
	fi

	# all
	if [ ! -d ${tajDBBCKDIR} ]; then
		chkret "${tajDBBCKDIR} is not a directory" stop
	fi

	# all
	if [ -z "${tajBCKLPATH}" ]; then
		chkret "Environment var tajBCKLPATH is undefined" stop
	fi

	# all
	if [ -z "${awsBUCKET}" ]; then
		chkret "Environment var awsBUCKET is undefined" stop
	fi

	# all
	if [ -z "${awsFOLDER}" ]; then
		chkret "Environment var awsFOLDER is undefined" stop
	fi

	# all
	if [ ! -d ${tajBCKLPATH} ]; then
		chkret "${tajBCKLPATH} is not a directory" stop
	fi

	# all
	if [ -z "${tajAPPREGION}" ]; then
		chkret "Environment var tajAPPREGION is undefined - must be one of: eu-west|us-east|us-west" stop
	else
		tajAPPREGION=$( echo "$tajAPPREGION"|tr '[:upper:]' '[:lower:]' )
		if [[ "$tajAPPREGION" =~ ^(eu-west|us-east|us-west)$ ]]; then
			# OK
			:
		else
			# NOT OK
			chkret "Environment var tajAPPREGION must be one of: eu-west|us-east|us-west" stop
		fi
	fi
	chkret "Region: ${tajAPPREGION}" log
	# all
	if [ -z "${tajAPPTYPE}" ]; then
		chkret "Environment var tajAPPTYPE is undefined - must be one of: origin|vision|web|utility" stop
	else
		tajAPPTYPE=$( echo "$tajAPPTYPE"|tr '[:upper:]' '[:lower:]' )
		if [[ "$tajAPPTYPE" =~ ^(origin|vision|web|utility)$ ]]; then
			# OK
			:
		else
			# NOT OK
			chkret "Environment var tajAPPTYPE must be one of: origin|vision|web|utility" stop
		fi
	fi
	chkret "APP type: ${tajAPPTYPE}" log

	# server-type specific checks
	if [ "$dbservertype" = "SLAVE" ]; then
		# slave backup, we care less
		:
	else
		# master, non-repl
		if [ -z "${tajPERIOD1FROM}" ]; then
			chkret "Environment var tajPERIOD1FROM is undefined" stop
		fi

		# master, non-repl
		if [ -z "${tajPERIOD1TO}" ]; then
		    chkret "Environment var tajPERIOD1TO is undefined" stop
		fi
	fi

}

chktime()
{
	# This time check function should allow at least 2 time windows as
	# these will vary across servers but generally 21:00 thru 23:00
	# and 02:00 thru 06:00. These times should be server specific

	# Backup window parameter checks
	p1frsec=`date -d "${tajPERIOD1FROM}" '+%s'`
	chkret "Conversion of Period1f to sec failed" fail
	p1tosec=`date -d "${tajPERIOD1TO}" '+%s'`
	chkret "Conversion of Period1f to sec failed" fail
	chkret "Period 1 window - ${tajPERIOD1FROM} to ${tajPERIOD1TO}" log

	# we only care about PERIOD2 if we aren't in PERIOD1
	if [ ! -z "${tajPERIOD2FROM}" ]; then
		if [ -z "${tajPERIOD2TO}" ]; then
  			chkret "Environment var tajPERIOD2TO is undefined but tajPERIOD2FROM is defined" stop
		else
			p2frsec=`date -d "${tajPERIOD2FROM}" '+%s'`
			chkret "Conversion of Period2f to sec failed" fail
			p2tosec=`date -d "${tajPERIOD2TO}" '+%s'`
			chkret "Conversion of Period2t to sec failed" fail
			chkret "Period 2 window - ${tajPERIOD2FROM} to ${tajPERIOD2TO}" log
		fi
	else
		# no period 2 - that's ok
		chkret "No period 2 defined" log
	fi

	nowsec=`date '+%s'`

	if [ \( $nowsec -ge $p1frsec \) -a \( $nowsec -le $p1tosec \) ]; then
		chkret "$p1frsec <= $nowsec <= $p1tosec : timecheck ok" log
		timecheck="OK"
	elif [ -z "$p2frsec" ]; then
		timecheck="NOTOK"
		chkret "No Period 2 specified so timecheck not ok" log
	elif [ \( $nowsec -ge $p2frsec \) -a \( $nowsec -le $p2tosec \) ]; then
		timecheck="OK"
	else
		chkret "$p1frsec <= $nowsec <= $p1tosec : timecheck p1 notok" log
		chkret "$p2frsec <= $nowsec <= $p2tosec : timecheck p2 notok" log
		chkret "Time check error - aborting.." fail
		timecheck="NOTOK"
	fi
	

	# Returns if no error, else stops/fails
}




chkdisk()
{
# This will need to use a variable that defines the device to be checked
# and incorporate similar processing to the tajdiskchecker to work out
# whether there is adequate space to continue backing up

	diskcheck="NOTOK"
	diskwait=60
	diskwaitcount=0
	diskmaxwaitcount=120 # 2 hours

	while [ $diskcheck != "OK" ]; do
		available_1kblocks=`df -k ${tajDBBCKDIR}|egrep -v "Filesystem.*Available"|egrep "%"| awk '{ if (NF == 5) {print $3} else {print $4} }'`
		chkret "attempt to determine available 1k blocks has failed" fail

	        # calculate the min space required by looking at the DB sizes
                # leave enough space for a few backups plus some binary logs
                dbsize=`echo "SELECT SUM(IF(ENGINE='MyISAM', DATA_LENGTH-DATA_FREE, DATA_LENGTH)+INDEX_LENGTH) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA NOT IN ('sys','performance_schema','information_schema')"|mysql -BN`
                chkret "attempt to determine db dump size failed" fail
                dumpspace_required=$((${dbsize}/10/1024))
                # we'll have contingency of x3 and assume a compression rate of 10%
                if [ $((3 * ${dumpspace_required})) -lt $available_1kblocks ]; then
echo "${dumpspace_required} -lt $available_1kblocks  / $dbsize"
                        diskcheck="OK"
                else
                        chkret "available 1K blocks is ${available_1kblocks} (require ${dumpspace_required})" log
                        chkret "Disk space deemed low - sleeping ${diskwait}" log
                        ((++diskwaitcount))
                        sleep ${diskwait}
                        if [ $diskwaitcount -gt $diskmaxwaitcount ]; then
                                chkret "Waited too long for disk space...${diskwaitcount} x ${diskwait}" stop
                        fi
                fi

	done
	# returns only if sufficient disk space
}

logtrim() {
	# trim database logs now we've successfully completed the backups
	if [ "${tajDBLOGTRIM}" = "yes" ]; then
		chkret "DB LOG trimming is enabled" log
   		chkret "trimdblogs - trimming to last 24 hours" log
		mysql -S ${mysqlSOCKET} > /dev/null <<!
PURGE BINARY LOGS BEFORE DATE_SUB( NOW( ), INTERVAL ${tajTRIMDAYS} DAY);
!
	fi
}

dohk() {
	# delete files older than tajBACKUPRETENTION days
	find $tajBCKLPATH/ -maxdepth 1 \( -name "dbbackup-full-*.tar" -or -name "dbbackup-errors-*.tar" \) -mtime +${tajBACKUPRETENTION} -exec rm -v {} \;
}

dbdump()
{
	# Single DB dump
	dbname=$1

	# get table list for DB
	chkret "Obtain list of tables for database ${dbname}" log
	# we never dump mysql log files
	mysql  -S ${mysqlSOCKET} -BN > ${tajDBBCKDIR}/${dbname}_tablist.txt <<!
	SELECT TABLE_NAME
	FROM INFORMATION_SCHEMA.TABLES
	WHERE TABLE_SCHEMA='${dbname}'
	AND (TABLE_SCHEMA <> 'mysql' OR (TABLE_SCHEMA='mysql' AND TABLE_NAME NOT IN ('event','slow_log','general_log')));
!
	chkret "MySQL creation of tablist failed - abort.." fail
	

	# table count
	tcnt=`wc -l ${tajDBBCKDIR}/${dbname}_tablist.txt | awk '{ print $1 }'`
	chkret "Database ${dbname} has $tcnt tables" log
	
	mkdir -p ${tajDBBCKDIR}/${dbname}
	chkret "Creation of directory: ${tajDBBCKDIR}/${dbname} failed " fail

	# create excluded tables list if one is defined
	touch ${tajDBBCKDIR}/${dbname}_excluded_tablist.txt
	if [ ${#tajEXCLUDETABS[@]} -gt 0 ]; then
		grep -i -f <( printf -- "%s\n" "${tajEXCLUDETABS[@]}" ) ${tajDBBCKDIR}/${dbname}_tablist.txt > ${tajDBBCKDIR}/${dbname}_excluded_tablist.txt
		if [ $? -gt 1 ]; then
			# error
			chkret "Generation of ${dbname} excluded tablist failed - abort.." fail
		else
			# zero or no lines returned
			chkret "Excluded tables list created:" log
			cat ${tajDBBCKDIR}/${dbname}_excluded_tablist.txt
		fi
	else
		chkret "No excluded tables defined" log
	fi


	# create included tables list
	grep -iv -f ${tajDBBCKDIR}/${dbname}_excluded_tablist.txt ${tajDBBCKDIR}/${dbname}_tablist.txt | awk -v dbname=${dbname} '{ printf "%s\t"$1"\n",dbname }' > ${tajDBBCKDIR}/${dbname}_included_tablist.txt
	chkret "Generation of ${dbname} included tablist failed - abort.." fail


	#######################################
	### START OF PARALLEL DUMP ###
	#######################################

	# Perform parallel table dump
	chkret "DB ${dbname}: Performing parallel dump" log

	# create directory
	chkret "Creating DB directory for ${dbname}" log
	mkdir -p $tajDBBCKDIR/${dbname}

	bakdate=`date --iso`
	baktime=`date "+%H%M%S"`

	export tajDBBCKDIR
	export bakdate
	export baktime
	export tajSUBDOMAIN
	export mysqlSOCKET

	# do dump
	if [ ! $DRY_RUN ]; then 
		xargs -L1 -P$tajDUMPTHREADS /bin/sh -c 'mysqldump  -S $mysqlSOCKET --skip-lock-tables -f "$1" "$2" 2> "$tajDBBCKDIR"/"$1"/dbbackup-table-"$bakdate"-"$1"-"$2"-"${tajSUBDOMAIN}"-"$baktime".log | gzip > "$tajDBBCKDIR"/"$1"/dbbackup-table-"$bakdate"-"$1"-"$2"-"${tajSUBDOMAIN}"-"$baktime".sql.gz' -- < ${tajDBBCKDIR}/${dbname}_included_tablist.txt
		chkret "Parallel dump failed - aborting.." fail

		# check log files for errors
		loglines=`cat ${tajDBBCKDIR}/${dbname}/*.log|wc -l`
		if [ $loglines -ne 0 ]; then
			cat ${tajDBBCKDIR}/${dbname}/*.log 
			chkret "MySQL dump logs ERRORS - aborting.." fail
		else
			chkret "MySQL dump logs OK.." log
		fi

		# md5sum of files
		chkret "Calculating MD5SUMs for ${dbname}" log
		md5sum $tajDBBCKDIR/${dbname}/dbbackup-table-${bakdate}-${dbname}-*-${tajSUBDOMAIN}-${baktime}.sql.gz > $tajDBBCKDIR/${dbname}/dbbackup-md5sum-${bakdate}-${dbname}-${tajSUBDOMAIN}-${baktime}.txt

		# check log files and alert if non-zero
		errorcount=`cat $tajDBBCKDIR/${dbname}/dbbackup-table-$bakdate-$dbname-*-${tajSUBDOMAIN}-$baktime.log|wc -l`
		if [ $errorcount -ne 0 ]; then
			chkret "ERRORS detected in logfiles" log
			# send an email? 
			# still archive the file, but warn of errors (using filename *errors*)
			touch $tajDBBCKDIR/${dbname}/COMPLETE-errors-${dbname}-${bakdate}-${baktime}
		else
			chkret "No errors detected in log file" log
			touch $tajDBBCKDIR/${dbname}/COMPLETE-full-${dbname}-${bakdate}-${baktime}
		fi
	else
		chkret "DRY_RUN only - not performing dump" log
	fi
	rm ${tajDBBCKDIR}/${dbname}_tablist.txt
	rm ${tajDBBCKDIR}/${dbname}_included_tablist.txt
	rm ${tajDBBCKDIR}/${dbname}_excluded_tablist.txt 
}

# tar files (parallel)
# move tar files to s3 upload directory
# upload to s3 and remove file


tar_backup_files() {
	# tar and remove if successful
	find /dbbackup/ -type f -name "COMPLETE-*" -printf "%f\n"|awk 'BEGIN{FS="-"}{print $2"\t"$3"\t"$4"-"$5"-"$6"\t"$7}' > $tarlistfile
	export tajDBBCKDIR
	export tajSUBDOMAIN
	export tajBCKLPATH
	chkret "Archiving tables" log
	xargs -L1 -P$tajDUMPTHREADS /bin/sh -c 'find ${tajDBBCKDIR}/"$2" \( -name "dbbackup-table-"$3"-"$2"-*-${tajSUBDOMAIN}-"$4".sql.gz" -or -name "dbbackup-md5sum-"$3"-"$2"-${tajSUBDOMAIN}-"$4".txt" -or -name "dbbackup-table-"$3"-"$2"-*-${tajSUBDOMAIN}-"$4".log" -or -name "COMPLETE-"$1"-"$2"-"$3"-"$4 -or -name "dbbackup-server-"$3"-${tajSUBDOMAIN}-*-"$4".*" \) -print0| tar --remove-files -cf $tajBCKLPATH/dbbackup-"$1"-"$3"-"$2"-${tajSUBDOMAIN}-"$4".tar --null -T -' -- < $tarlistfile
	# S3 sync

}

move_to_s3() {
	export awsBUCKET
	export awsFOLDER
	export tajBCKLPATH
	export tajSUBDOMAIN
	chkret "Uploading files to S3 from ${tajBCKLPATH} to ${awsBUCKET}/${awsFOLDER}" log
	chkret "$(cat ${tarlistfile})" log
	xargs -L1 -P$tajDUMPTHREADS /bin/sh -c '~/bin/aws s3 cp --only-show-errors ${tajBCKLPATH}/dbbackup-"$1"-"$3"-"$2"-${tajSUBDOMAIN}-"$4".tar s3://${awsBUCKET}/${awsFOLDER}/ && rm -fv ${tajBCKLPATH}/dbbackup-"$1"-"$3"-"$2"-${tajSUBDOMAIN}-"$4".tar || echo "FAILED to copy to AWS S3: ${tajBCKLPATH}/dbbackup-"$1"-"$3"-"$2"-${tajSUBDOMAIN}-"$4".tar"' -- < $tarlistfile
}

am_i_a_master() {
	# determine if we are a master server
	ismaster=1
	# this is not easy - we need to use application specific info
	chkret "Checking for ${tajAPPTYPE} master server " log
	if [[ "${tajAPPTYPE}" = "origin" || "${tajAPPTYPE}" = "vision" ]]; then
		ips=(`hostname -i`)
		ips+=("localhost")

		if [ "${tajAPPTYPE}" = "origin" ]; then
			# collect IPs of DB hosts serving customers from hostedclient
			chkret "Obtaining client connections for $mysqlSOCKET" log
			dbhost=(hostname)
			chkret "Failed to obtain client connections from esellerpromaster.hostedclient table" fail
		elif [ "${tajAPPTYPE}" = "vision" ]; then
			# assumes domain names for connect string rather than IP addresses
			dbhost=()
			dbhostnames=(your hostname)
			chkret "Failed to obtain client connections from provisualise.clientconnections table" fail
			for n in ${dbhostnames[@]}; do 
				dig=(`dig +short $n`)
				dbhost+=( "${dig[@]}" )
			done
		fi
	
		if [ ${#dbhost[@]} -eq 0 ]; then
			# no DBs defined, empty Origin DB server?
			chkret "No databases are currently inuse. Server not presently being used" log
			ismaster=1
		elif [ `comm -1 -2 <(printf '%s\n' "${ips[@]}" | sort) <(printf '%s\n' "${dbhost[@]}" | sort)|wc -l` -gt 0 ]; then
			# intersection of DB hosts and this server's ip addresses > 0, therefore this server hosts at least one database
			# must be a master server as part of a m-m configuration (i.e. is a "slave"!)
			# OR it could be an old slave config which isn't used in which case treating as MASTER is ok
			chkret "This server hosts DBs for the application ${tajAPPTYPE}" log
			ismaster=1
		else
			# doesn't appear to have DBs on this server likely to be a slave
			chkret "This server does not host any DBs for the application ${tajAPPTYPE}" log
			ismaster=0
		fi

	else
		# assume we are a master server (we cannot determine)
		chkret "Assuming we are a master - unable to determine from app specific information" log
		ismaster=1
	fi
}

am_i_a_slave() {
	# determine if configured as a slave
	isslave=0

	# Cache MySQL slave configuration
	slave_status=$(echo "SHOW SLAVE STATUS;" | /usr/bin/mysql -S $mysqlSOCKET -B)

	# Check MySQL slave configured
	chkret "Checking for MySQL slave configuration..." log
	regex=$'^.*\n.*$'
	if [[ $slave_status =~ $regex ]]; then
		chkret "Slave config present" log
		isslave=1
	else
		chkret "No slave configuration" log
	fi

}

get_db_server_type() {

	# Function to determine how this DB server operates and hence which backup type to perform

	# Check MySQL installed
	[[ -x /usr/bin/mysql && -x /usr/bin/mysqldump ]] || chkret "Requires MySQL client" fail

	# WE NEED A RELIABLE METHOD TO IDENTIFY SLAVE TO AVOID PROBLEMS SETTING MASTER AS READ_ONLY

	# Types to handle
	# 1. Origin - determine master, slave, non-repl using esellerpromaster.hostedclient
	# 2. Vision - determine master, slave, non-repl using provisualise.clientconnections
	# 3. Web - determine master, slave from params else non-repl
	# 4. Utility - determine master, slave from params else non-repl

	# 1. Master - no locks, relevant dbs only
	# 2. Slave - locks, all dbs
	# 3. Non-repl - no locks, relevant dbs only, can trim binary logs

        # tajFORCESLAVEBACKUP=0
        # tajFORCEMASTERBACKUP=0

	# am I a slave?
	am_i_a_slave
	# am I a master?
	am_i_a_master

	dbservertype="MASTER"
	if [ ${ismaster} -eq 1 ]; then
		if [[ "${tajAPPTYPE}" = "origin" && ${isslave} -eq 1 ]]; then
			# master and slave - likely replicating from a combo box
			if [ ${tajFORCESLAVEBACKUP} -eq 1 ]; then
				# we can override to perform slave backup for origin only if slave AND master AND 
				# force slave backup override is set (i.e. need to trust manual setting!)
				chkret "tajFORCESLAVEBACKUP=1 - forcing SLAVE backup" log
				dbservertype="SLAVE"
			fi
		elif [[ "${tajAPPTYPE}" = "web" || "${tajAPPTYPE}" = "utility" ]]; then
			if [ ${tajFORCESLAVEBACKUP} -eq 1 ]; then
				# we can override to perform slave backup only for web|utility as we currently have no way to determine 
				# if the server is acting as a master (i.e. need to trust manual setting!)
				chkret "tajFORCESLAVEBACKUP=1 - forcing SLAVE backup" log
				dbservertype="SLAVE"
			fi
		elif [ ${isslave} -eq 0 ]; then
			# origin/vision - master, but no slave configured. Must be a non-replication server. Can trim logs.
			# NOTE: if acting as master in Master-Slave config, then this will likely break replication if delays exceed the purge log time.
			# At present, we do not have this arrangement except on web stores DB servers.
			dbservertype="NONREPL"
		else
			# always choose master backup
			dbservertype="MASTER"
		fi
	elif [ ${isslave} -eq 1 ]; then
		if [ ${tajFORCEMASTERBACKUP} -eq 1 ]; then
			dbservertype="MASTER"
		else
			# not a master (i.e. not identifiable as a master from app info), has slave config, and is not set to FORCEMASTERBACKUP
			dbservertype="SLAVE"
		fi
	elif [ ${isslave} -eq 0 ]; then
		if [ ${tajFORCEMASTERBACKUP} -eq 1 ]; then
			chkret "tajFORCEMASTERBACKUP=1 - forcing MASTER backup" log
                        dbservertype="MASTER"
		elif [[ "${tajAPPTYPE}" = "web" || "${tajAPPTYPE}" = "utility" ]]; then
			if [ ${tajFORCESLAVEBACKUP} -eq 1 ]; then
				# we can override to perform slave backup only for web|utility (i.e. need to trust manual setting!)
				chkret "tajFORCESLAVEBACKUP=1 - forcing SLAVE backup" log
				dbservertype="SLAVE"
			fi
		else
			# this is likely an unknown state as master defaults to 1
			dbservertype="NONREPL"
		fi
	fi

	chkret "This is a ${dbservertype} server" log
}

dobackup() {

	# Are we half-way through a previous backup session?
	if [ -r ${tajDBBCKDIR}/checkpoint ]; then
		tajCHECKPOINT=`cat ${tajDBBCKDIR}/checkpoint`
	fi

	if [ -z "${tajDUMPTHREADS}" ]; then
		chkret "Environment var tajDUMPTHREADS is undefined, using default" log
		tajDUMPTHREADS=4
	fi

	# Construct database list for backup
	if [ -z "${tajDBLISTSQL}" ]; then
		# no custom SQL found for schema list
                tajDBLISTSQL="SELECT s.SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA s WHERE s.SCHEMA_NAME NOT IN ('sys','performance_schema','information_schema')"
	else
		# found SQL
		:
	fi
	chkret "Running SQL to determine schema list: ${tajDBLISTSQL}" log
	echo ${tajDBLISTSQL} | mysql -S $mysqlSOCKET -BN > ${tajDBBCKDIR}/dblist.txt
	chkret "Failed to set dblist from database" fail
	# add extra DBs
	printf '%s\n' "${tajEXTRADBS[@]}" >> ${tajDBBCKDIR}/dblist.txt
	count=`wc -l ${tajDBBCKDIR}/dblist.txt | awk '{ print $1 }'`
	chkret "Extracted backup list contains $count databases" log 

	# Move DBs up to the checkpoint DB to the end of the list
	# so that we can utilise the whole backup window
	seendbs=()
	newdbs=()
	custdbs=()
	for dbname in `cat ${tajDBBCKDIR}/dblist.txt`
	do
		if [ ! -z "$tajCHECKPOINT" ]; then
			chkret "var tajCHECKPOINT is $tajCHECKPOINT" log
			if [ $tajCHECKPOINT != $dbname ]; then
				chkret "Checkpoint exists - moving to end of list ${dbname}" log
				seendbs+=( $dbname );
			else
				seendbs+=( $dbname );
				unset tajCHECKPOINT;
				chkret "Checkpoint reached - moving to end of list ${dbname}" log
			fi;
		else
			newdbs+=( $dbname );
		fi;
	done;

	# rejoin arrays together - in a different order
	custdbs=( "${newdbs[@]}" "${seendbs[@]}" );
	chkret "${custdbs[@]}" log

	# cycle through DBs list
	for custdb in ${custdbs[@]}
	do
		baktime=`date "+%H%M%S"`
		chkdisk
		chktime
		if [ $timecheck != "OK" ]; then
			chkret "Not authorised to run at this time" log
			# break - i.e. continue with tar + s3 upload
			break
		fi

		chkret "Commencing processing of $custdb" log
		echo "$custdb" > ${tajDBBCKDIR}/checkpoint
	
		# Dump database
		dbdump $custdb
		chkret "Extraction of customer database $custdb failed - aborting.." fail
	done
}



chkret() {
	retcode=$?
	tstamp=`date +%H:%M:%S`
	#
	if [ $2 == log ]; then
	        echo "$tstamp - $SCRIPT - $1"
	        return
	fi
	#
	if [ $2 == stop ]; then
		echo "$tstamp - $SCRIPT - $1"
		exit 1
	fi
#
	if [ $retcode != 0 ]; then
        	echo "$tstamp - $SCRIPT - $1"
		exit 1
	fi
return
}


dobackupslave() {

	# https://dev.mysql.com/doc/refman/5.5/en/replication-solutions-backups-read-only.html

	bakdate=`date --iso`
	baktime=`date "+%H%M%S"`

	# Stop slave if started and ensure it's restarted later
	slave_running=$(
	        echo "$slave_status" | awk '
        	        BEGIN { FS="\t"; IGNORECASE=1 }
	                NR==1 { for (i=1;i<=NF;++i) if ($i~"slave") c[$i]=i; next }
        	        { for (i in c) print i,"=",$c[i]; nextfile }
                	'
	        )
	chkret "$slave_running" log
	regex=$'Slave_.*_Running = Yes(\n|$)'

	if [[ $slave_running =~ $regex ]]; then
        	chkret "${DRY_RUN:+Dry run: }mysql> STOP SLAVE SQL_THREAD;" log
	        [ $DRY_RUN ] || echo "STOP SLAVE SQL_THREAD;" | /usr/bin/mysql -S $mysqlSOCKET -B

	        start_slave() {
        	        chkret "${DRY_RUN:+Dry run: }mysql> START SLAVE SQL_THREAD;" log
                	[ $DRY_RUN ] || echo "START SLAVE SQL_THREAD;" | /usr/bin/mysql -S $mysqlSOCKET -B
        	}
	        trap "start_slave;clearup" INT TERM EXIT
	fi

	if [ -z "${tajDUMPTHREADS}" ]; then
		chkret "Environment var tajDUMPTHREADS is undefined, using default" log
		tajDUMPTHREADS=4
	fi

	# create table list
	# get table list for customer DB

	chkret "Obtaining list of tables for all databases" log
	tablistfile="$tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-tablist-${baktime}.txt"
	mysql -S $mysqlSOCKET -BN > $tablistfile <<!
SELECT TABLE_SCHEMA, CONCAT('"',TABLE_NAME,'"')
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA NOT IN ('sys','performance_schema','information_schema','mysql')
OR (TABLE_SCHEMA='mysql' AND TABLE_NAME NOT IN ('event','slow_log','general_log'));
!

	# create directories
	chkret "Creating DB directories" log
	dblist=`cat ${tablistfile}|cut -f1|sort|uniq`
	for dbname in ${dblist[@]}; do 
		mkdir -p $tajDBBCKDIR/${dbname}

		# save hostedclient entry
		mysqldump -S $mysqlSOCKET  esellerpromaster hostedclient --where "DBName='${dbname}'" > $tajDBBCKDIR/${dbname}/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-${dbname}-hostedclient-${baktime}.sql
	done

	# get DB count
	# mysqlump
	status=`cat ${tablistfile}|cut -f1|sort|uniq -c | tee ${tajDBBCKDIR}/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-dblist-${baktime}.txt`
	dbcount=`cat ${tablistfile}|cut -f1|sort|uniq|wc -l`
	chkret "Found ${dbcount} databases to backup:" log
	chkret "${status}" log

	chkret "Saving master and slave configurations" log
	if [ ! $DRY_RUN ]; then 
		# save master status
		mysql -S $mysqlSOCKET -X -e "SHOW MASTER STATUS" > $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-master-status-${baktime}.txt
		# save slave status
		mysql -S $mysqlSOCKET -X -e "SHOW SLAVE STATUS" > $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-slave-status-${baktime}.txt
		# backup info
		# date, time, filenames
		cat > $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-info-${baktime}.txt <<EOT
server=${tajSUBDOMAIN}
backup-date=${bakdate}
backup-time=${baktime}
dbcount=${dbcount}
EOT
	else
		chkret "DRY_RUN - not saving master/log positions" log
	fi

	# export variables for xargs
	export tajDBBCKDIR
	export baktime
	export bakdate
	export tajSUBDOMAIN
	export mysqlSOCKET

	# do dump
	chkret "Dumping database tables with ${tajDUMPTHREADS} threads to $tajDBBCKDIR" log
	if [ ! $DRY_RUN ]; then 
		xargs -L1 -P$tajDUMPTHREADS /bin/sh -c 'mysqldump -S $mysqlSOCKET "$1" "$2" 2> "$tajDBBCKDIR"/"$1"/dbbackup-table-"$bakdate"-"$1"-"$2"-"${tajSUBDOMAIN}"-"$baktime".log | gzip > "$tajDBBCKDIR"/"$1"/dbbackup-table-"$bakdate"-"$1"-"$2"-"${tajSUBDOMAIN}"-"$baktime".sql.gz' -- < $tablistfile
		chkret "Parallel dump failed - aborting.." fail
		chkret "Dump complete" log

		# restart slave
		[ $DRY_RUN ] || start_slave

		for dbname in ${dblist[@]}; do

			# md5sum of files
			chkret "Calculating MD5SUMs for ${dbname}" log
			md5sum $tajDBBCKDIR/${dbname}/dbbackup-table-${bakdate}-${dbname}-*-${tajSUBDOMAIN}-${baktime}.sql.gz > $tajDBBCKDIR/${dbname}/dbbackup-md5sum-${bakdate}-${dbname}-${tajSUBDOMAIN}-${baktime}.txt

			# check log files and alert if non-zero
			errorcount=`cat $tajDBBCKDIR/${dbname}/dbbackup-table-$bakdate-$dbname-*-${tajSUBDOMAIN}-$baktime.log|wc -l`
			if [ $errorcount -ne 0 ]; then
				chkret "ERRORS detected in logfiles" log
				# send an email? 
				# still archive the file, but warn of errors (using filename *errors*)
				touch $tajDBBCKDIR/${dbname}/COMPLETE-errors-${dbname}-${bakdate}-${baktime}
			else
				chkret "No errors detected in log file" log
				touch $tajDBBCKDIR/${dbname}/COMPLETE-full-${dbname}-${bakdate}-${baktime}
			fi

			# copy server files into DB directory
			cp $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-*-${baktime}.txt $tajDBBCKDIR/${dbname}/

		done
	else
		chkret "DRY_RUN only - not performing dump" log
	fi

	if [ ! $DRY_RUN ]; then
		rm $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-slave-status-${baktime}.txt
		rm $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-master-status-${baktime}.txt
		rm $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-info-${baktime}.txt
		rm $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-tablist-${baktime}.txt
		rm $tajDBBCKDIR/dbbackup-server-${bakdate}-${tajSUBDOMAIN}-dblist-${baktime}.txt

	fi
	chkret "Slave backup complete" log
}


clearup() {
  # clearup on exit
  rm -f $lockfile
}

##################
# MAIN execution #
##################
# Now we're going to do something....


lockfile=/tmp/`basename $0 | sed 's/.sh//'`.lock
if [ ! -e $lockfile ]; then
   trap clearup INT TERM EXIT
   touch $lockfile

   [ ! $DRY_RUN ]|| chkret "DRY RUN" log
   initparams
   chkparams
   get_db_server_type
   if [ "$dbservertype" = "MASTER" ]; then
   #	if [ $tajFORCEMASTERBACKUP -eq 1 ]; then
   #		# do master backup
   		chkret "Performing master backup" log
   		do_master_backup
   #	else
   #		# cannot perform backup without override
   #		chkret "Cannot perform backup on master. Use tajFORCEMASTERBACKUP=1 to override" stop
   #	fi
   elif [ "$dbservertype" = "SLAVE" ]; then
  	# do slave backup
	chkret "Performing slave backup" log
	do_slave_backup
   else
	# do safe / non-replication server backup
	# non-intrusive, no locking etc
	chkret "Performing non-replication server backup" log
	do_nonrepl_backup
   fi

   # now archive and upload to S3
   tarlistfile=$(mktemp)
   tar_backup_files
   move_to_s3
   rm ${tarlistfile}

   # Completed backup - remove checkpoint
   if [ -r ${tajDBBCKDIR}/checkpoint ]; then
  	rm ${tajDBBCKDIR}/checkpoint
   fi
   chkret "Database backup process is complete, removed checkpoint file" log

   rm $lockfile
   # clear trap
   trap - INT TERM EXIT
else
   echo `basename $0`" is already running"
fi
# vim: ts=2 sw=2 et :





