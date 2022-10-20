#!/bin/bash

# vim: sw=2:et

#########################################################################
#                                                                       #
#       Usage: ./mysql-performance-check.sh [ mode ]                    #
#                                                                       #
#       Available Modes:                                                #
#               all :           perform all checks (default)            #
#               prompt :        prompt for login credentials and socket #
#                               and execution mode                      #
#               mem, memory :   run checks for tunable options which    #
#                               affect memory usage                     #
#               disk, file :    run checks for options which affect     #
#                               i/o performance or file handle limits   #
#               innodb :        run InnoDB checks /* to be improved */  # 
#               misc :          run checks that don't fit categories    #
#                               well Slow Queries, Binary logs,         #
#                               Used Connections and Worker Threads     #
#########################################################################
#                                                                       #
# Set this socket variable ONLY if you have multiple instances running  # 
# or we are unable to find your socket, and you don't want to to be     #
# prompted for input each time you run this script.                     #
#                                                                       #
#########################################################################
socket=

function colorize() {
  # As an explicit special case, "" yields sgr0 (i.e., black).
  local originalcolor="${1}"
  local basecolor="${originalcolor}"

  basecolor="${basecolor#bold}"
  basecolor="${basecolor#so}"

  case "$basecolor" in
    'red')
      tput setaf 1 ;;
    'green')
      tput setaf 2 ;;
    'yellow')
      tput setaf 3 ;;
    'blue')
      tput setaf 4 ;;
    'magenta')
      tput setaf 5 ;;
    'cyan')
      tput setaf 6 ;;
    'white')
      tput setaf 7 ;;
    *) # Also "black":
      [ "$basecolor" != "black" ] && [ -n "$basecolor" ] && echo "No such color '$basecolor'." >&2
      tput sgr0 ;;
  esac

  # bold, etc.
  if [ "$basecolor" != "$originalcolor" ]; then
    case $originalcolor in
      bold*)
        tput bold ;;
      so*)
        tput smso ;;
      *)
        echo "No such color modifier '${originalcolor%$basecolor}'." >&2 ;;
    esac
  fi
}

function cecho()
{
  if [ -z "${1-}" ]; then
    cecho "No message passed." "${2-}"
    return $?
  fi
  cechon "$1"$'\n' "${2-}" "${3-}"
  return $?
}

function cechon()
{
## -- Function to easily print colored text -- ##
        
        # Color-echo.
        # Argument $1 = message
        # Argument $2 = color
        # Argument $3 = skip write file
  local default_msg="No message passed."

  message=${1:-$default_msg}    # Defaults to default message.

  #change it for fun
  #We use pure names
  color=${2:-black}             # Defaults to black, if not specified.

  colorize "$color"
  printf "%s"  "$message"
  colorize ""                   # Reset to normal.
  
  if [ -z "${3-}"  ]; then 
  	echo $message >> "./output.txt"
  fi

return
}

function write_mycnf() {
  # $1: Path to .my.cnf
  # $2: Path to socket (optional)
  # $3: username
  # $4: password
  local socketcomment=""
  [ -z "$2" ] && socketcomment="#"
  local cleanpassword="${4//\\/\\\\}"
  cleanpassword="${cleanpassword//\"/\\\"}"
  cat > "${1}" <<EOF
[client]
${socketcomment}socket=$2
user=$3
password="${cleanpassword}"
EOF
}

function print_banner()
{
  cecho " -- MYSQL PERFORMANCE TUNING PRIMER --" boldblue 0
}

## -- Find the location of the mysql.sock file -- ##
function check_for_socket()
{
  if [ -n "$socket" ] && [ ! -S "$socket" ]; then
    # If you specify a socket but that socket doesn't exist, we exit.
    cecho "No valid socket file at '$socket'!" boldred
    cecho "You've explicitly specified a socket location, but that location either" red
    cecho "doesn't exist, or isn't a socket." red
    exit 1
  fi

  # Otherwise, try to find the socket.  Failure is now OK; we can always
  # try another way to connect.
  if [ -z "$socket" ] ; then
    # Use ~/.my.cnf version
    if [ -f ~/.my.cnf ] ; then
      # Use the last one we find in the file.  We could be smarter here and
      # parse section headers and so forth, but meh.
      cnf_socket="$(awk -F '=' '$1 == "socket" { s=$2 } END { print s }' ~/.my.cnf)"
    fi

    if [ -S "$cnf_socket" ] ; then
      socket=$cnf_socket
    elif [ -S /var/lib/mysql/mysql.sock ] ; then
      socket=/var/lib/mysql/mysql.sock
    elif [ -S /var/run/mysqld/mysqld.sock ] ; then
      socket=/var/run/mysqld/mysqld.sock
    elif [ -S /tmp/mysql.sock ] ; then
      socket=/tmp/mysql.sock
    else
      if [ -S "$ps_socket" ] ; then
      socket=$ps_socket
      fi
    fi
  fi

  if [ -S "$socket" ] ; then
    export MYSQL_COMMAND="${MYSQL_COMMAND} -S ${socket}"
	cecho "socket = ${socket}"
    return 0
  fi
  
  return 1
}


check_for_plesk_passwords () {

## -- Check for the existance of plesk and login using its credentials -- ##

  if [ -f /etc/psa/.psa.shadow ] ; then
    MYSQL_COMMAND="mysql -S $socket -u admin -p$(cat /etc/psa/.psa.shadow)"
    MYSQLADMIN_COMMAND="mysqladmin -S $socket -u admin -p$(cat /etc/psa/.psa.shadow)"
  fi
}

check_mysql_login () {

## -- Try just connecting (i.e., via .my.cnf defaults, in practice) -- ##

  local is_up=$($MYSQLADMIN_COMMAND ping 2>&1)
  local print_defaults=$($MYSQLADMIN_COMMAND --print-defaults 2>/dev/null)

  if [ "$is_up" = "mysqld is alive" ]; then
    if [ "${print_defaults//*--host=*}" = "" ] &&
     ! [ "${print_defaults//*--host=127\.0\.0\.1*}" = "" ] &&
     ! [ "${print_defaults//*--host=::1*}" = "" ] &&
     ! [ "${print_defaults//*--host=localhost*}" = "" ]; then
      cecho "WARNING: you might be connecting to a remote server.  If so, some" boldred
      cecho "results may be based on incorrect assumptions.  See #13 on Github." boldred
    fi
    return 0
  fi
  printf "\n"
  cecho "Using login values from ~/.my.cnf" 
  cecho "- INITIAL LOGIN ATTEMPT FAILED -" boldred
  if [ -z $prompted ] ; then
    find_webmin_passwords
  fi
  return 1
}

final_login_attempt () {
  is_up=$($MYSQLADMIN_COMMAND ping 2>&1)
  if [ "$is_up" = "mysqld is alive" ] ; then
    return 0
  else
    cecho "- FINAL LOGIN ATTEMPT FAILED -" boldred
    cecho "Unable to log into socket: $socket" boldred
    exit 1
  fi
}

## -- create a ~/.my.cnf and exit when all else fails -- ##
function second_login_failed()
{
  cecho "Could not auto detect login info!"
  cecho "Found potential sockets: $(xargs <<< "$found_socks")"
  if [ -z "$socket" ]; then
    cecho "  Will use client's default socket (this is normally correct)." bold
  else
    cecho "  Choosing: $socket" red
  fi
  read -rp "Would you like to override my socket choice?: [y/N] " REPLY
    case $REPLY in 
      yes | y | Y | YES)
      read -rp "Socket: " socket
      ;;
    esac
  read -rp "Do you have your login handy ? [y/N] : " REPLY
  case $REPLY in 
    yes | y | Y | YES)
    answer1='yes'
    read -rp "User: " user
    read -rsp "Password: " pass

    export MYSQL_COMMAND="mysql"
    export MYSQLADMIN_COMMAND="mysqladmin"

    ;;
    *)
    cecho "Please create a valid login to MySQL"
    cecho "Or, set correct values for 'user=' and 'password=' in ~/.my.cnf"
    ;;
  esac
  cecho " "
  echo "Would you like me to create a ~/.my.cnf file for you?  If you answer 'N',"
  read -p "then I'll create a secure, temporary one instead.  [y/N] : " REPLY
  case $REPLY in
    yes | y | Y | YES)
    answer2='yes'
    if [ ! -f ~/.my.cnf ] ; then
      umask 077
      write_mycnf "${HOME}/.my.cnf" "$socket" "$user" "$pass"
      if [ "$answer1" != 'yes' ] ; then
        exit 1
      else
        final_login_attempt
        return 0
      fi
    else
      printf "\n"
      cecho "~/.my.cnf already exists!" boldred
      printf "\n"
      read -p "Replace ? [y/N] : " REPLY
      if [ "$REPLY" = 'y' ] || [ "$REPLY" = 'Y' ] ; then 
        write_mycnf "${HOME}/.my.cnf" "$socket" "$user" "$pass"
        if [ "$answer1" != 'yes' ] ; then
          exit 1
        else
          final_login_attempt
          return 0
        fi
      else
        cecho "Please set the 'user=' and 'password=' and 'socket=' values in ~/.my.cnf"
        exit 1
      fi
    fi
    ;;
    *)
    if [ "$answer1" != 'yes' ] ; then
      exit 1
    else
      local tempmycnf
      tempmycnf="$(mktemp)"
      write_mycnf "$tempmycnf" "$socket" "$user" "$pass"
      export MYSQL_COMMAND="mysql --defaults-extra-file=$tempmycnf $MYSQL_COMMAND_PARAMS"
      export MYSQLADMIN_COMMAND="mysqladmin --defaults-extra-file=$tempmycnf $MYSQL_COMMAND_PARAMS"
      final_login_attempt
      return 0
    fi
    ;;
  esac
}

find_webmin_passwords () {

## -- populate the .my.cnf file using values harvested from Webmin -- ##

        cecho "Testing for stored webmin passwords:"
        if [ -f /etc/webmin/mysql/config ] ; then
                user=$(grep ^login= /etc/webmin/mysql/config | cut -d "=" -f 2)
                pass=$(grep ^pass= /etc/webmin/mysql/config | cut -d "=" -f 2)
                if [  $user ] && [ $pass ] && [ ! -f ~/.my.cnf  ] ; then
                        cecho "Setting login info as User: $user Password: $pass"
                        touch ~/.my.cnf
                        chmod 600 ~/.my.cnf
                        write_mycnf "${HOME}/.my.cnf" "" "$user" "$pass"
                        cecho "Retrying login"
                        is_up=$($MYSQLADMIN_COMMAND ping 2>&1)
                        if [ "$is_up" = "mysqld is alive"  ] ; then
                                echo UP > /dev/null
                        else
                                second_login_failed
                        fi
                echo
                else
                        second_login_failed
                echo
                fi
        else
        cecho " None Found" boldred
                second_login_failed
        fi
}

#########################################################################
#                                                                       #
#  Function to pull MySQL status variable                               #
#                                                                       #
#  Call using :                                                         #
#       mysql_status \'Mysql_status_variable\' bash_dest_variable       #
#                                                                       #
#########################################################################

mysql_status () {
        local status=$($MYSQL_COMMAND -Bse "show /*!50000 global */ status like $1" | awk '{ print $2 }')
        export "$2"=$status
		cecho "$2 = $status"
}

#########################################################################
#                                                                       #
#  Function to pull MySQL server runtime variable                       #
#                                                                       #
#  Call using :                                                         #
#       mysql_variable \'Mysql_server_variable\' bash_dest_variable     #
#       - OR -                                                          #
#       mysql_variableTSV \'Mysql_server_variable\' bash_dest_variable  #
#                                                                       #
#########################################################################

mysql_variable () {
  local variable=$($MYSQL_COMMAND -Bse "show /*!50000 global */ variables like $1" | awk '{ print $2 }')
  export "$2"=$variable
  cecho "$2 = $variable"
}
mysql_variableTSV () {
  local variable=$($MYSQL_COMMAND -Bse "show /*!50000 global */ variables like $1" | awk -F '\t' '{ print $2 }')
  export "$2"=$variable
  cecho "$2 = $variable"
}

# -- Divide two integers -- #
function divide()
{
  usage="$0 dividend divisor '$variable' scale"
  if [ $1 -ge 1 ] ; then
    dividend=$1
  else
    cecho "Invalid Dividend" red
    echo "$usage"
    exit 1
  fi
  if [ $2 -ge 1 ] ; then
    divisor=$2
  else
    cecho "Invalid Divisor" red
    echo "$usage"
    exit 1
  fi
  if [ ! -n $3 ] ; then
    cecho "Invalid variable name" red
    echo "$usage"
    exit 1
  fi
  if [ -z $4 ] ; then
    scale=2
  elif [ $4 -ge 0 ] ; then
    scale=$4
  else
    cecho "Invalid scale" red
    echo "$usage"
    exit 1
  fi
  export $3=$(echo "scale=$scale; $dividend / $divisor" | bc -l)
  cecho "$3 = $3"
}

check_mysql_version () {

## -- Print Version Info -- ##

        mysql_variable \'version\' mysql_version
        mysql_variable \'version_compile_machine\' mysql_version_compile_machine
        cecho "mysql_version = $mysql_version"
        cecho "mysql_version_compile_machine = $mysql_version_compile_machine"
        
if [ "$mysql_version_num" -lt 050000 ]; then
        cecho "MySQL Version $mysql_version $mysql_version_compile_machine is EOL please upgrade to MySQL 4.1 or later" boldred
else
        cecho "MySQL Version $mysql_version $mysql_version_compile_machine"
fi


}

post_uptime_warning () {

#########################################################################
#                                                                       #
#  Present a reminder that mysql must run for a couple of days to       #
#  build up good numbers in server status variables before these tuning #
#  suggestions should be used.                                          #
#                                                                       #
#########################################################################

        mysql_status \'Uptime\' uptime
        mysql_status \'Threads_connected\' threads
        queries_per_sec=$(($questions/$uptime))
        # cecho "uptime = $uptime"
        cecho "threads_connected = $threads"
        cecho "queries_per_sec = $queries_per_sec"
		cecho "mysql_version_num = $mysql_version_num"

}

check_slow_queries () {

## -- Slow Queries -- ## 
        cecho "SLOW QUERIES" boldblue 0

        mysql_status \'Slow_queries\' slow_queries
        mysql_variable \'long_query_time\' long_query_time
        mysql_variable \'log%queries\' log_slow_queries
        mysql_variable \'slow_query_log\' slow_query_log
		
		cecho "slow_queries = $slow_queries"
		cecho "long_query_time = $long_query_time"
		cecho "log_slow_queries = $log_slow_queries"
		cecho "slow_query_log = $slow_query_log"
}

check_binary_log () {

## -- Binary Log -- ##

        cecho "BINARY UPDATE LOG" boldblue 0

        mysql_variable \'log_bin\' log_bin
        mysql_variable \'max_binlog_size\' max_binlog_size
        mysql_variable \'expire_logs_days\' expire_logs_days
        mysql_variable \'sync_binlog\' sync_binlog
        #  mysql_variable \'max_binlog_cache_size\' max_binlog_cache_size
        cecho "log_bin = $log_bin"
		cecho "max_binlog_size = $max_binlog_size"
        cecho "expire_logs_days = $expire_logs_days"
		cecho "sync_binlog = $sync_binlog"

}

check_used_connections () {

## -- Used Connections -- ##

        mysql_variable \'max_connections\' max_connections
        mysql_status \'Max_used_connections\' max_used_connections
        mysql_status \'Threads_connected\' threads_connected

        connections_ratio=$(($max_used_connections*100/$max_connections))
		cecho "max_connections = $max_connections"
		cecho "max_used_connections = $max_used_connections"
		cecho "threads_connected = $threads_connected"
		cecho "connections_ratio = $connections_ratio"
}

check_threads() {

## -- Worker Threads -- ##

        cecho "WORKER THREADS" boldblue 0

        mysql_status \'Threads_created\' threads_created1
        sleep 1
        mysql_status \'Threads_created\' threads_created2

        mysql_status \'Threads_cached\' threads_cached
        # mysql_status \'Uptime\' uptime
        mysql_variable \'thread_cache_size\' thread_cache_size

        historic_threads_per_sec=$(($threads_created1/$uptime))
        current_threads_per_sec=$(($threads_created2-$threads_created1)) 
		
		cecho "threads_cached = $threads_cached"
		cecho "thread_cache_size = $thread_cache_size"
		cecho "historic_threads_per_sec = $historic_threads_per_sec"
		cecho "current_threads_per_sec = $current_threads_per_sec"
}

check_key_buffer_size () {

## -- Key buffer Size -- ##

        cecho "KEY BUFFER" boldblue 0

        mysql_status \'Key_read_requests\' key_read_requests
        mysql_status \'Key_reads\' key_reads
        mysql_status \'Key_blocks_used\' key_blocks_used
        mysql_status \'Key_blocks_unused\' key_blocks_unused
        mysql_variable \'key_cache_block_size\' key_cache_block_size
        mysql_variable \'key_buffer_size\' key_buffer_size
        mysql_variable \'datadir\' datadir
        mysql_variable \'version_compile_machine\' mysql_version_compile_machine
        myisam_indexes=$($MYSQL_COMMAND -Bse "/*!50000 SELECT IFNULL(SUM(INDEX_LENGTH),0) from information_schema.TABLES where ENGINE='MyISAM' */")
		cecho "key_read_requests = $key_read_requests"
		cecho "key_reads = $key_reads"
		cecho "key_blocks_used = $key_blocks_used"
		cecho "key_blocks_unused = $key_blocks_unused"
		cecho "key_cache_block_size = $key_cache_block_size"
		cecho "key_buffer_size = $key_buffer_size"
		cecho "datadir = $datadir"
		cecho "mysql_version_compile_machine = $mysql_version_compile_machine"
		

        if [ -z $myisam_indexes ] ; then
                myisam_indexes=$(find $datadir -name '*.MYI' -exec du $duflags '{}' \; 2>&1 | awk '{ s += $1 } END { printf("%.0f\n", s )}')
        fi
		cecho "myisam_indexes = $myisam_indexes"
}

check_query_cache () {

## -- Query Cache -- ##

        cecho "QUERY CACHE" boldblue 0

        mysql_variable \'version\' mysql_version
        mysql_variable \'query_cache_size\' query_cache_size
        mysql_variable \'query_cache_limit\' query_cache_limit
        mysql_variable \'query_cache_min_res_unit\' query_cache_min_res_unit
        mysql_status \'Qcache_free_memory\' qcache_free_memory
        mysql_status \'Qcache_total_blocks\' qcache_total_blocks
        mysql_status \'Qcache_free_blocks\' qcache_free_blocks
        mysql_status \'Qcache_lowmem_prunes\' qcache_lowmem_prunes
		
		cecho "version = $mysql_version" 
		cecho "query_cache_size = $query_cache_size" 
		cecho "query_cache_limit = $query_cache_limit" 
		cecho "query_cache_min_res_unit = $query_cache_min_res_unit" 
		cecho "qcache_free_memory = $qcache_free_memory" 
		cecho "qcache_total_blocks = $qcache_total_blocks" 
		cecho "qcache_free_blocks = $qcache_free_blocks" 
		cecho "qcache_lowmem_prunes = $qcache_lowmem_prunes" 

}

check_sort_operations () {

## -- Sort Operations -- ##

        cecho "SORT OPERATIONS" boldblue 0

        mysql_status \'Sort_merge_passes\' sort_merge_passes
        mysql_status \'Sort_scan\' sort_scan
        mysql_status \'Sort_range\' sort_range
        mysql_variable \'sort_buffer_size\' sort_buffer_size 
        mysql_variable \'read_rnd_buffer_size\' read_rnd_buffer_size 
		cecho "sort_merge_passes = $sort_merge_passes" 
		cecho "sort_scan = $sort_scan" 
		cecho "sort_range = $sort_range" 
		cecho "sort_buffer_size = $sort_buffer_size" 
		
        total_sorts=$(($sort_scan+$sort_range))
		cecho "total_sorts = $total_sorts" 
        if [ -z $read_rnd_buffer_size ] ; then
                mysql_variable \'record_buffer\' read_rnd_buffer_size
        fi
		
        ## Correct for rounding error in mysqld where 512K != 524288 ##
        sort_buffer_size=$(($sort_buffer_size+8))
        read_rnd_buffer_size=$(($read_rnd_buffer_size+8))
		cecho "sort_buffer_size = $sort_buffer_size" 
		cecho "read_rnd_buffer_size = $read_rnd_buffer_size" 
	
}

check_join_operations () {

## -- Joins -- ##

        cecho "JOINS" boldblue 0

        mysql_status \'Select_full_join\' select_full_join
        mysql_status \'Select_range_check\' select_range_check
        mysql_variable \'join_buffer_size\' join_buffer_size
		
		cecho "select_full_join = $select_full_join" 
		cecho "select_range_check = $select_range_check" 
		cecho "join_buffer_size = $join_buffer_size" 
}

check_tmp_tables () {

## -- Temp Tables -- ##

        cecho "TEMP TABLES" boldblue 0

        mysql_status \'Created_tmp_tables\' created_tmp_tables 
        mysql_status \'Created_tmp_disk_tables\' created_tmp_disk_tables
        mysql_variable \'tmp_table_size\' tmp_table_size
        mysql_variable \'max_heap_table_size\' max_heap_table_size

		cecho "created_tmp_tables = $created_tmp_tables" 
		cecho "created_tmp_disk_tables = $created_tmp_disk_tables" 
		cecho "tmp_table_size = $tmp_table_size" 
		cecho "max_heap_table_size = $max_heap_table_size" 
}

check_open_files () {

## -- Open Files Limit -- ## 
        cecho "OPEN FILES LIMIT" boldblue 0

        mysql_variable \'open_files_limit\' open_files_limit
        mysql_status   \'Open_files\' open_files
		cecho "open_files_limit = $open_files_limit" 
		cecho "open_files = $open_files" 
	
}

check_table_cache () {

## -- Table Cache -- ##

        cecho "TABLE CACHE" boldblue 0

        mysql_variable \'datadir\' datadir
        mysql_variable \'table_cache\' table_cache
		
		cecho "datadir = $datadir" 
		cecho "table_cache = $table_cache" 

        ## /* MySQL +5.1 version of table_cache */ ## 
        mysql_variable \'table_open_cache\' table_open_cache
        mysql_variable \'table_definition_cache\' table_definition_cache
		cecho "table_open_cache = $table_open_cache" 
		cecho "table_definition_cache = $table_definition_cache" 

        mysql_status \'Open_tables\' open_tables
        mysql_status \'Opened_tables\' opened_tables
        mysql_status \'Open_table_definitions\' open_table_definitions
		cecho "open_tables = $open_tables" 
		cecho "opened_tables = $opened_tables" 
		cecho "open_table_definitions = $open_table_definitions" 
 
        table_count=$($MYSQL_COMMAND -Bse "/*!50000 SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' */")
		cecho "table_count = $table_count" 
		cecho "uid = $UID" 
}

check_table_locking () {

## -- Table Locking -- ##

        cecho "TABLE LOCKING" boldblue 0

        mysql_status \'Table_locks_waited\' table_locks_waited
        mysql_status \'Table_locks_immediate\' table_locks_immediate
        mysql_variable \'concurrent_insert\' concurrent_insert
        mysql_variable \'low_priority_updates\' low_priority_updates
		cecho "table_locks_waited = $table_locks_waited" 
		cecho "table_locks_immediate = $table_locks_immediate" 
		cecho "concurrent_insert = $concurrent_insert" 
		cecho "low_priority_updates = $low_priority_updates" 
	
}

check_table_scans () {

## -- Table Scans -- ##

        cecho "TABLE SCANS" boldblue 0

        mysql_status \'Com_select\' com_select
        mysql_status \'Handler_read_rnd_next\' read_rnd_next
        mysql_variable \'read_buffer_size\' read_buffer_size
		cecho "com_select = $com_select" 
		cecho "handler_read_rnd_next = $read_rnd_next" 
		cecho "read_buffer_size = $read_buffer_size" 
	
}

function check_innodb_status()
{
  ## See http://bugs.mysql.com/59393

  mysql_variable \'have_innodb\' have_innodb
  cecho "have_innodb = $have_innodb" 

  if [ "$mysql_version_num" -lt 050500 ] && [ "$have_innodb" = "YES" ] ; then
    innodb_enabled=1
  fi

  if [ "${mysql_version//Maria}" != "${mysql_version}" ] || \
     [ "${mysql_version_num}" -ge 050700 ]; then
    # In MariaDB and MySQL >=5.7, InnoDB is always present, excepting Rocks and the like.
    mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
    # MariaDB gives you a lovely option for disabling InnoDB that doesn't _technically_
    # necessitate setting ignore_builtin_innodb.  Thanks for that.  Very cute.  See
    # https://github.com/BMDan/tuning-primer.sh/issues/12 .
    if [ "$ignore_builtin_innodb" = "ON" ] || [ "$have_innodb" = "DISABLED" ] || [ "$have_innodb" = "NO" ]; then
      innodb_enabled=0
    else
      innodb_enabled=1
    fi
  elif [ "$mysql_version_num" -ge 050500 ] && [ "$mysql_version_num" -lt 050512 ] ; then
    mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
    if [ "$ignore_builtin_innodb" = "ON" ] || [ $have_innodb = "NO" ] ; then
      innodb_enabled=0
    else
      innodb_enabled=1
    fi
  elif [ "$major_version"  = '5.5' ] && [ "$mysql_version_num" -ge 050512 ] ; then
    mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
    if [ "$ignore_builtin_innodb" = "ON" ] ; then
      innodb_enabled=0
    else
      innodb_enabled=1
    fi
  elif [ "$mysql_version_num" -ge 050600 ] && [ "$mysql_version_num" -lt 050603 ] ; then
    mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
    if [ "$ignore_builtin_innodb" = "ON" ] || [ $have_innodb = "NO" ] ; then
      innodb_enabled=0
    else
      innodb_enabled=1
    fi
  elif [ "$major_version" = '5.6' ] && [ "$mysql_version_num" -ge 050603 ] ; then
    mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
    if [ "$ignore_builtin_innodb" = "ON" ] ; then
      innodb_enabled=0
    else
      innodb_enabled=1
    fi
  fi

  if [ "$innodb_enabled" = 1 ] ; then
    mysql_variable \'innodb_buffer_pool_size\' innodb_buffer_pool_size
    mysql_variable \'innodb_additional_mem_pool_size\' innodb_additional_mem_pool_size
    mysql_variable \'innodb_fast_shutdown\' innodb_fast_shutdown
    mysql_variable \'innodb_flush_log_at_trx_commit\' innodb_flush_log_at_trx_commit
    mysql_variable \'innodb_locks_unsafe_for_binlog\' innodb_locks_unsafe_for_binlog
    mysql_variable \'innodb_log_buffer_size\' innodb_log_buffer_size
    mysql_variable \'innodb_log_file_size\' innodb_log_file_size
    mysql_variable \'innodb_log_files_in_group\' innodb_log_files_in_group
    mysql_variable \'innodb_safe_binlog\' innodb_safe_binlog
    mysql_variable \'innodb_thread_concurrency\' innodb_thread_concurrency
	  
	cecho "innodb_buffer_pool_size = $innodb_buffer_pool_size" 
	cecho "innodb_additional_mem_pool_size = $innodb_additional_mem_pool_size" 
	cecho "innodb_fast_shutdown = $innodb_fast_shutdown" 
	cecho "innodb_flush_log_at_trx_commit = $innodb_flush_log_at_trx_commit" 
	cecho "innodb_locks_unsafe_for_binlog = $innodb_locks_unsafe_for_binlog" 
	cecho "innodb_log_buffer_size = $innodb_log_buffer_size" 
	cecho "innodb_log_file_size = $innodb_log_file_size" 
	cecho "innodb_log_files_in_group = $innodb_log_files_in_group" 
	cecho "innodb_safe_binlog = $innodb_safe_binlog" 
	cecho "innodb_thread_concurrency = $innodb_thread_concurrency" 


    cecho "INNODB STATUS" boldblue 0
    innodb_indexes=$($MYSQL_COMMAND -Bse "/*!50000 SELECT IFNULL(SUM(INDEX_LENGTH),0) from information_schema.TABLES where ENGINE='InnoDB' */")
    innodb_data=$($MYSQL_COMMAND -Bse "/*!50000 SELECT IFNULL(SUM(DATA_LENGTH),0) from information_schema.TABLES where ENGINE='InnoDB' */")
	cecho "innodb_indexes = $innodb_indexes" 
	cecho "innodb_data = $innodb_data" 

    if [ ! -z "$innodb_indexes" ] ; then
      mysql_status \'Innodb_buffer_pool_pages_data\' innodb_buffer_pool_pages_data
      mysql_status \'Innodb_buffer_pool_pages_misc\' innodb_buffer_pool_pages_misc
      mysql_status \'Innodb_buffer_pool_pages_free\' innodb_buffer_pool_pages_free
      mysql_status \'Innodb_buffer_pool_pages_total\' innodb_buffer_pool_pages_total

      mysql_status \'Innodb_buffer_pool_read_ahead_seq\' innodb_buffer_pool_read_ahead_seq
      mysql_status \'Innodb_buffer_pool_read_requests\' innodb_buffer_pool_read_requests

      mysql_status \'Innodb_os_log_pending_fsyncs\' innodb_os_log_pending_fsyncs
      mysql_status \'Innodb_os_log_pending_writes\'   innodb_os_log_pending_writes
      mysql_status \'Innodb_log_waits\' innodb_log_waits

      mysql_status \'Innodb_row_lock_time\' innodb_row_lock_time
      mysql_status \'Innodb_row_lock_waits\' innodb_row_lock_waits
	  cecho "innodb_buffer_pool_pages_data = $innodb_buffer_pool_pages_data" 
	  cecho "innodb_buffer_pool_pages_misc = $innodb_buffer_pool_pages_misc" 
	  cecho "innodb_buffer_pool_pages_free = $innodb_buffer_pool_pages_free" 
	  cecho "innodb_buffer_pool_pages_total = $innodb_buffer_pool_pages_total" 
	  cecho "innodb_buffer_pool_read_ahead_seq = $innodb_buffer_pool_read_ahead_seq" 
	  cecho "innodb_buffer_pool_read_requests = $innodb_buffer_pool_read_requests" 
	  cecho "innodb_os_log_pending_fsyncs = $innodb_os_log_pending_fsyncs" 
	  cecho "innodb_os_log_pending_writes = $innodb_os_log_pending_writes" 
	  cecho "innodb_log_waits = $innodb_log_waits" 
	  cecho "innodb_row_lock_time = $innodb_row_lock_time" 
	  cecho "innodb_row_lock_waits = $innodb_row_lock_waits" 
    else
     	innodb_status=$($MYSQL_COMMAND -s -e "SHOW /*!50000 ENGINE */ INNODB STATUS\G")
		cecho "innodb_status = $innodb_status" 
    fi
  fi
}

total_memory_used () {

## -- Total Memory Usage -- ##
        cecho "MEMORY USAGE" boldblue 0

        mysql_variable \'read_buffer_size\' read_buffer_size
        mysql_variable \'read_rnd_buffer_size\' read_rnd_buffer_size
        mysql_variable \'sort_buffer_size\' sort_buffer_size
        mysql_variable \'thread_stack\' thread_stack
        mysql_variable \'max_connections\' max_connections
        mysql_variable \'join_buffer_size\' join_buffer_size
        mysql_variable \'tmp_table_size\' tmp_table_size
        mysql_variable \'max_heap_table_size\' max_heap_table_size
        mysql_variable \'log_bin\' log_bin
        mysql_status \'Max_used_connections\' max_used_connections
	    cecho "read_buffer_size = $read_buffer_size" 
	    cecho "read_rnd_buffer_size = $read_rnd_buffer_size" 
	    cecho "sort_buffer_size = $sort_buffer_size" 
	    cecho "thread_stack = $thread_stack" 
	    cecho "max_connections = $max_connections" 
	    cecho "join_buffer_size = $join_buffer_size" 
	    cecho "tmp_table_size = $tmp_table_size" 
	    cecho "max_heap_table_size = $max_heap_table_size" 
	    cecho "log_bin = $log_bin" 
		cecho "max_used_connections = $max_used_connections" 
		

        if [ "$major_version" = "3.23" ] ; then
                mysql_variable \'record_buffer\' read_buffer_size
                mysql_variable \'record_rnd_buffer\' read_rnd_buffer_size
                mysql_variable \'sort_buffer\' sort_buffer_size
			    cecho "read_buffer_size = $read_buffer_size" 
			    cecho "read_rnd_buffer_size = $read_rnd_buffer_size" 
				cecho "sort_buffer_size = $sort_buffer_size" 
				
        fi
#
        if [ "$log_bin" = "ON" ] ; then
                mysql_variable \'binlog_cache_size\' binlog_cache_size
				cecho "binlog_cache_size = $binlog_cache_size" 
        else
                binlog_cache_size=0
        fi
		
        per_thread_buffers=$(echo "($read_buffer_size+$read_rnd_buffer_size+$sort_buffer_size+$thread_stack+$join_buffer_size+$binlog_cache_size)*$max_connections" | bc -l)
        per_thread_max_buffers=$(echo "($read_buffer_size+$read_rnd_buffer_size+$sort_buffer_size+$thread_stack+$join_buffer_size+$binlog_cache_size)*$max_used_connections" | bc -l)
	    cecho "per_thread_buffers = $per_thread_buffers" 
	    cecho "per_thread_max_buffers = $per_thread_max_buffers" 


        mysql_variable \'innodb_buffer_pool_size\' innodb_buffer_pool_size
		cecho "innodb_buffer_pool_size = $innodb_buffer_pool_size" 
        if [ -z $innodb_buffer_pool_size ] ; then
        	innodb_buffer_pool_size=0
        fi

        mysql_variable \'innodb_additional_mem_pool_size\' innodb_additional_mem_pool_size
		cecho "innodb_additional_mem_pool_size = $innodb_additional_mem_pool_size" 
        if [ -z $innodb_additional_mem_pool_size ] ; then
       		innodb_additional_mem_pool_size=0
        fi

        mysql_variable \'innodb_log_buffer_size\' innodb_log_buffer_size
		cecho "innodb_log_buffer_size = $innodb_log_buffer_size"
        if [ -z $innodb_log_buffer_size ] ; then
        	innodb_log_buffer_size=0
        fi

        mysql_variable \'key_buffer_size\' key_buffer_size
		cecho "key_buffer_size = $key_buffer_size"

        mysql_variable \'query_cache_size\' query_cache_size
		cecho "query_cache_size = $query_cache_size"
		
        if [ -z $query_cache_size ] ; then
        	query_cache_size=0
        fi

        global_buffers=$(echo "$innodb_buffer_pool_size+$innodb_additional_mem_pool_size+$innodb_log_buffer_size+$key_buffer_size+$query_cache_size" | bc -l)
		cecho "global_buffers = $global_buffers"


        max_memory=$(echo "$global_buffers+$per_thread_max_buffers" | bc -l)
        total_memory=$(echo "$global_buffers+$per_thread_buffers" | bc -l)
		cecho "max_memory = $max_memory"
		cecho "total_memory = $total_memory"

        pct_of_sys_mem=$(echo "scale=0; $total_memory*100/$physical_memory" | bc -l)
		cecho "pct_of_sys_mem = $pct_of_sys_mem"
}

## Required Functions  ## 

login_validation () {
        export MYSQL_COMMAND="mysql"
        export MYSQLADMIN_COMMAND="mysqladmin"

        if [ -n "${socket-}" ]; then
          # First, we look for a socket.  Then, we try to find old Plesk
          # login creds (is this still needed?).  Then, we try the truly
          # revolutionary approach of just trying to connect and seeing
          # what happens.
          check_for_socket ||
          check_for_plesk_passwords ||
          check_mysql_login ||
          exit 1
        else
          # If the user didn't specify a socket for us (and they usually
          # won't), let's try to just connect and see if that works.  If
          # it doesn't, try to guess at a socket path, and then break out
          # the ol' Plesk trick if things get really desperate.
          check_mysql_login ||
          check_for_socket ||
          check_for_plesk_passwords ||
          exit 1
        fi
        export major_version=$($MYSQL_COMMAND -Bse "SELECT SUBSTRING_INDEX(VERSION(), '.', +2)")
#       export mysql_version_num=$($MYSQL_COMMAND -Bse "SELECT LEFT(REPLACE(SUBSTRING_INDEX(VERSION(), '-', +1), '.', ''),4)" )
        export mysql_version_num=$($MYSQL_COMMAND -Bse "SELECT VERSION()" | 
                awk -F \. '{ printf "%02d", $1; printf "%02d", $2; printf "%02d", $3 }')
		cecho "mysql_version_num = $mysql_version_num"
		cecho "major_version = $major_version"			
					

}

shared_info () {
        export major_version=$($MYSQL_COMMAND -Bse "SELECT SUBSTRING_INDEX(VERSION(), '.', +2)")
        # export mysql_version_num=$($MYSQL_COMMAND -Bse "SELECT LEFT(REPLACE(SUBSTRING_INDEX(VERSION(), '-', +1), '.', ''),4)" )
        export mysql_version_num=$($MYSQL_COMMAND -Bse "SELECT VERSION()" | 
                awk -F \. '{ printf "%02d", $1; printf "%02d", $2; printf "%02d", $3 }')
		cecho "major_version = $major_version"
		cecho "mysql_version_num = $mysql_version_num"
        mysql_status \'Questions\' questions
		cecho "questions = $questions"
#       socket_owner=$(find -L $socket -printf '%u\n')
        socket_owner=$(ls -nH $socket | awk '{ print $3 }')
		# cecho "socket_owner = $socket_owner"
}
        
get_system_info () {
	outputfile="./output.txt"
	if [ -f $outputfile ] ; then
		rm -f $outputfile
		touch $outputfile
	else
		touch $outputfile
	fi

    export OS=$(uname)
    
    # Get information for various UNIXes
    if [ "$OS" = 'Darwin' ]; then
        ps_socket=$(netstat -ln | awk '/mysql(.*)?\.sock/ { print $9 }' | head -1)
        found_socks=$(netstat -ln | awk '/mysql(.*)?\.sock/ { print $9 }')
        export physical_memory=$(sysctl -n hw.memsize)
        export duflags=''
		cecho "physical_memory = $physical_memory"
		cecho "duflags = $duflags"
    elif [ "$OS" = 'FreeBSD' ] || [ "$OS" = 'OpenBSD' ]; then
        ## On FreeBSD must be root to locate sockets.
        ps_socket=$(netstat -ln | awk '/mysql(.*)?\.sock/ { print $9 }' | head -1)
        found_socks=$(netstat -ln | awk '/mysql(.*)?\.sock/ { print $9 }')
        export physical_memory=$(sysctl -n hw.realmem)
        export duflags=''
		cecho "physical_memory = $physical_memory"
		cecho "duflags = $duflags"
    elif [ "$OS" = 'Linux' ] ; then
        ## Includes SWAP
        ## export physical_memory=$(free -b | grep -v buffers |  awk '{ s += $2 } END { printf("%.0f\n", s ) }')
        ps_socket=$(netstat -ln | awk '/mysql(.*)?\.sock/ { print $9 }' | head -1)
        found_socks=$(netstat -ln | awk '/mysql(.*)?\.sock/ { print $9 }')
        export physical_memory=$(awk '/^MemTotal/ { printf("%.0f", $2*1024 ) }' < /proc/meminfo)
        export duflags='-b'
		cecho "physical_memory = $physical_memory"
		cecho "duflags = $duflags"
    elif [ "$OS" = 'SunOS' ] ; then
        ps_socket=$(netstat -an | awk '/mysql(.*)?.sock/ { print $5 }' | head -1)
        found_socks=$(netstat -an | awk '/mysql(.*)?.sock/ { print $5 }') 
        export physical_memory=$(prtconf | awk '/^Memory\ size:/ { print $3*1048576 }')
		cecho "physical_memory = $physical_memory"
    fi
    if [ -z "$(which bc)" ] ; then
        echo "Error: Command line calculator 'bc' not found!"
        exit
    fi
	
}


## Optional Components Groups ##

banner_info () {
        shared_info
        print_banner            ; echo
        check_mysql_version     ; echo
        post_uptime_warning     ; echo
}

misc () {
        shared_info
        check_slow_queries      ; echo
        check_binary_log        ; echo
        check_threads           ; echo
        check_used_connections  ; echo
        check_innodb_status     ; echo
}

memory () {
        shared_info
        total_memory_used       ; echo
        check_key_buffer_size   ; echo
        check_query_cache       ; echo
        check_sort_operations   ; echo
        check_join_operations   ; echo
}

file () {
        shared_info
        check_open_files        ; echo
        check_table_cache       ; echo
        check_tmp_tables        ; echo
        check_table_scans       ; echo
        check_table_locking     ; echo
}

all () {
        banner_info
        misc
        memory
        file
}

prompt () {
        prompted='true'
        read -p "Username [anonymous] : " user
        read -rsp "Password [<none>] : " pass
        cecho " "
        read -p "Socket [ /var/lib/mysql/mysql.sock ] : " socket
        if [ -z $socket ] ; then
                export socket='/var/lib/mysql/mysql.sock'
        fi

        local tempmycnf
        tempmycnf="$(mktemp)"
        write_mycnf "$tempmycnf" "$socket" "$user" "$pass"

        export MYSQL_COMMAND="mysql --defaults-extra-file=$tempmycnf -u$user"
        export MYSQLADMIN_COMMAND="mysqladmin --defaults-extra-file=$tempmycnf -u$user"

        check_for_socket || \
        check_mysql_login

        if [ $? = 1 ] ; then
                exit 1
        fi
        read -p "Mode to test - banner, file, misc, mem, innodb, [all] : " REPLY
        if [ -z $REPLY ] ; then
                REPLY='all'
        fi
        case $REPLY in
                banner | BANNER | header | HEADER | head | HEAD)
                banner_info 
                ;;
                misc | MISC | miscelaneous )
                misc
                ;;
                mem | memory |  MEM | MEMORY )
                memory
                ;; 
                file | FILE | disk | DISK )
                file
                ;;
                innodb | INNODB )
                innodb
                ;;
                all | ALL )
                cecho " "
                all
                ;;
                * )
                cecho "Invalid Mode!  Valid options are 'banner', 'misc', 'memory', 'file', 'innodb' or 'all'" boldred
                exit 1
                ;;
        esac 
}

## Address environmental differences ##
get_system_info
# echo $ps_socket

mode="$1"
if [ -z "${1-}" ] ; then
  login_validation
  mode='ALL'
elif [ "$1" != "prompt" ] && [ "$1" != "PROMPT" ] ; then
  login_validation
fi

case $mode in 
  all | ALL )
    cecho " "
    all
    ;;
  mem | memory |  MEM | MEMORY )
    cecho " "
    memory
    ;;
  file | FILE | disk | DISK )
    cecho " "
    file
    ;;
  banner | BANNER | header | HEADER | head | HEAD )
    banner_info
    ;;
  misc | MISC | miscelaneous )
    cecho " "
    misc
    ;;
  innodb | INNODB )
    banner_info
    check_innodb_status ; echo
    ;;
  prompt | PROMPT )
    prompt
    ;;
  debug | DEBUG )
    # Run everything, then dump state.
    all >/dev/null
    env
    ;;
  *)
    cecho "usage: $0 [ all | banner | file | innodb | memory | misc | prompt ]" boldred
    exit 1  
    ;;
esac