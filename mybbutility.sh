#!/bin/bash

#set -o xtrace

# Settings.

# Verbose output level: 0 - quiet; 1 error; 2 - warning; 3 - normal; 4 - debug information.
MYBB_UTILITY_VERBOSE_LEVEL=3

# Usually, there's no need to change the following settings.
MYBB_COM="mybb.com"
MYBB_URL="https://mybb.com/"
MYBB_VER_CHECK_URL_BASE="https://mybb.com/version_check.php"
MYBB_RELEASE_URL_BASE="https://mybb.com/versions/{MYBB_VERCODE}/"
MYBB_DOWNLOAD_URL_BASE="https://resources.mybb.com/downloads/mybb_{MYBB_VERCODE}.zip"
MYBB_RELEASE_CHECKSUMS_URL_BASE="https://mybb.com/checksums/release_mybb_{MYBB_VERCODE}.txt"

# The no-backup list of files and directories (directory entry ending with a trailing slash "/").
# ! Entries in the list will NOT GET BACKED UP.
# ! MyBB-generated cache files (eg., theme stylesheets, etc.) and user uploaded attachments and avatars (in ./uploads/ directory) will NOT GET BACKED UP.
#   Eg., if you don't want the utility to back up a specifc MyBB file "./htaccess.txt" and directory "./install/", then add "./htaccess.txt" and "./install/" into the list, double quotes included, space separated. Then the variable will be like:
#   MYBB_UTILITY_NO_BACKUP_LIST=("./uploads/" "./cache/")
MYBB_UTILITY_NO_BACKUP_LIST=()

# The no-touch list of files and directories (directory entry ending with a trailing slash "/").
# ! Entries in the list will NOT GET REMOVED OR UPDATED.
#   Eg., if you don't want the utility to remove/update existing English language pack, then add "./inc/languages/english/" and "./inc/languages/english.php" into the list, space separated. Then the variable will be like:
#   MYBB_UTILITY_NO_TOUCH_LIST=("./inc/languages/english/" "./inc/languages/english.php")
MYBB_UTILITY_NO_TOUCH_LIST=()

_SCRIPT_NAME="MyBB Utility"
_SCRIPT_VER="0.1"
_SCRIPT_VERCODE="0"
_SCRIPT="$0"
_CURRENT_DIR="$(pwd)"
_CMD=""
_EXIT_CODE=0

_DATE_NOW="$(date +%Y%m%d%H%M%S)"
_MYBB_CLASS_FILE="inc/class_core.php"

# Usage: $0 $1 $2
# Tell if a string ($1) starts with a character/string ($2).
# Returns: 0 if true, 1 otherwise.
# $1 string
# $2 string
function _starts_with() {
	local str="$1"
	local substr="$2"

	if [ "${str: 0: ${#substr}}" == "${substr}" ]
	then
		return 0;
	else
		return 1;
	fi
}

function do_get_abspath {
	if [ -d "$1" ]
	then
		pushd "$1" >/dev/null
		pwd
		popd >/dev/null
	elif [ -e "$1" ]
	then
		pushd "$(dirname "$1")" >/dev/null
		echo "$(pwd)/$(basename "$1")"
		popd >/dev/null
	else
		return 127
	fi
}

function do_get_permissions() {
	local perms
	perms=$(stat --dereference --printf="%a" "$1" 2>/dev/null)
	echo "${perms}"
}

function do_check_permission() {
	local perms perm perm_to_check checked
	perms=$(do_get_permissions "$1")
	perm_to_check="$2"
	case "${perm_to_check}" in
		uread)
			perm=${perms: -3: 1}
			checked=$(( 4 & $perm))
			;;
		uwrite)
			perm=${perms: -3: 1}
			checked=$(( 2 & $perm))
			;;
		uexec)
			perm=${perms: -3: 1}
			checked=$(( 1 & $perm))
			;;
		gread)
			perm=${perms: -2: 1}
			checked=$(( 4 & $perm))
			;;
		gwrite)
			perm=${perms: -2: 1}
			checked=$(( 2 & $perm))
			;;
		gexec)
			perm=${perms: -2: 1}
			checked=$(( 1 & $perm))
			;;
		oread)
			perm=${perms: -1: 1}
			checked=$(( 4 & $perm))
			;;
		owrite)
			perm=${perms: -1: 1}
			checked=$(( 2 & $perm))
			;;
		oexec)
			perm=${perms: -1: 1}
			checked=$(( 1 & $perm))
			;;
		*)
			checked=-1
			;;
	esac

	if [ $checked -gt 0 ]
	then
		checked=1
	fi
	echo "${checked}"
}

function do_prepare_folder() {
	local path checked_perm result
	path=$1
	mkdir -p "${path}" 2>/dev/null
	if [ -d "${path}" ]
	then
		result=1
		checked_perm=$(do_check_permission "${path}" "uwrite")
		if [ ${checked_perm} -eq 1 ]
		then
			result=0
		#else
		#	chmod a+w "${path}" 2>&1 >/dev/null
		#	checked_perm=$(do_check_permission "${path}" "uwrite")
		#	if [ ${checked_perm} -eq 1 ]
		#	then
		#		result=0
		#	fi
		fi
	else
		result=-1
	fi

	echo "${result}"
}

function do_validate_url(){
	if [[ `wget -S --spider "$1"  2>&1 | grep 'HTTP/1.1 200 OK'` ]]
	then
		return 0
	else
		return 1
	fi
}

function do_download_url() {
	local url dest
	url="$1"
	if [ -n "$2" ]
	then
		dest=$2
		$(wget -q -O "${dest}" "${url}" 2>/dev/null)
	else
		# Destination is stdout.
		dest=$(wget -qO- "${url}" 2>/dev/null)
		echo "${dest}"
	fi
}

function do_verify_file() {
	local input checksum checksum_util checked
	input="$1"
	checksum_util="$2"
	checksum="$3"

	checksum_util=$(which "${checksum_util}")
	if [ -z "${checksum_util}" ]
	then
		return
	fi

	if [ "${checksum}" == "?" ]
	then
		MYBB_UPGRADER_IGNORE_CHECKSUM=1
	fi

	checked=$("${checksum_util}" "${input}" 2>/dev/null)
	checked="${checked: 0: 128}"
	if [ ${MYBB_UPGRADER_IGNORE_CHECKSUM} -ne 1 ]
	then
		if [ "${checksum}" == "${checked}" ]
		then
			checked=$(echo "0:${checked}")
		else
			checked=$(echo "1:${checked}")
		fi
	else
		checked=$(echo "?:${checked}")
	fi

	echo "${checked}"
}

function do_get_xml_matched_by_tag() {
	local string tag pattern match
	string=$1
	tag=$2
	# (?<=(<pre>))(\w|\d|\n|[().,\-:;@#$%^&*\[\]"'+–/\/®°⁰!?{}|`~]| )+?(?=(</pre>))
	pattern=$'(?<=(<tag>))(\w|\d|\\n|[().,\-:;@#$%^&*\[\]"\'+–/\/®°⁰!?{}|`~]| )+?(?=(</tag>))'
	pattern=${pattern//tag/"${tag}"}
	match=$(echo "${string}" | grep -PoZ "${pattern}" 2>/dev/null)
	echo "${match}"
}

function do_get_release_xml_matched_by_tag() {
	local string tag pattern matched1 matched2 matched3
	string=$1
	tag=$2
	# [[:blank:]]*\<([a-zA-Z0-9_]*)\>(.*)\</([a-zA-Z0-9_]*)\>
	pattern='[[:blank:]]*<tag>(.*)</tag>'
	pattern=${pattern//tag/"${tag}"}

	if [[ "${string}" =~ ${pattern} ]]
	then
		matched1="${BASH_REMATCH[1]}"
		echo "${matched1}"
	fi

	echo ""
}

function do_debug() {
	exit
}

function do_print_msg() {
	if [ "$1" == "debugvar" ] && [ ${MYBB_UTILITY_VERBOSE_LEVEL} -gt 3 ]
	then
		shift
		if [ -z "$1" ]
		then
			return
		fi

		local array count i j
		array=("$@")
		count=${#array[*]}
		count=$(( count / 2))
		echo "[debug] Printing ${count} variable(s):"

		count=$(( count * 2))
		i=0
		while [ $i -lt $count ]
		do
			j=$(( i + 1 ))
			echo "[debug] \$${array[$i]}: ${array[$j]}"
			i=$(( j + 1 ))
		done
	elif [ "$1" == "debugmsg" ] && [ ${MYBB_UTILITY_VERBOSE_LEVEL} -gt 3 ]
	then
		shift
		echo -e "[debug] $@"
	elif [ "$1" == "info" ] && [ ${MYBB_UTILITY_VERBOSE_LEVEL} -gt 2 ]
	then
		shift
		#echo -e "[${_SCRIPT_NAME^^}] ${@}"
		echo -e "[info.] ${@}"
	elif [ "$1" == "warn" ] && [ ${MYBB_UTILITY_VERBOSE_LEVEL} -gt 1 ]
	then
		shift
		echo -e "[warn.] ${@}"
	elif [ "$1" == "error" ] && [ ${MYBB_UTILITY_VERBOSE_LEVEL} -gt 0 ]
	then
		shift
		echo -e "[error] ${@}"
	fi
	#echo "[@#\$%]"
}

function do_print_version() {
	echo "${_SCRIPT_NAME} ${_SCRIPT_VER}"
}

function do_print_usage() {
	echo "Usage: ${_SCRIPT} [command] ... [parameters ...]"
	echo
	echo "Try \`$0 --help' for more options."
}

function do_print_help() {
	do_print_version
	echo "Usage: ${_SCRIPT} [command] ... [parameters ...]
Commands:
  showver, -v, --version            Show version info.
  showhelp, -h, --help              Show this help message.
  showinst, --show-instance         Show meta information of a MyBB instance.
  verifyinst, --verify-instance     Verify a MyBB instance.
  showrlsinfo, --show-release-info  Get and show the meta information of a MyBB
                                      release.
  getrls, --get-release             Download a MyBB release and extract the
                                      archive.
  install, --install                Install a MyBB release.
  remove, --remove                  Remove a MyBB instance.
  backup, --backup                  Bakcup a MyBB instance.
  restore, --restore                Restore a MyBB instance from a backup.
  update, --update                  Update a MyBB instance.

Parameters:
  -i, --instance-dir <directory>    Specifies the dir for a MyBB instance. This
                                      dir should be readable and writable in
                                      order for the script to execute specified
                                      actions.
  -w, --working-dir <directory>     Specifies the dir for the script to work.
                                      This dir should be readable and writable
                                      in order for the script to do specified
                                      jobs.
                                      Caution: the current directory (by \`pwd\`)
                                      will be used if none is given.
      --instance-ver <ver. code>    Specifies the version code (eg. 1820) of a
                                      MyBB instance. The script will try to
                                      figure out the version code from the
                                      installed instance if none is given.
      --release-ver <ver. code>     Specifies the version code (eg. 1820) of a
                                      MyBB release. The script will try to get
                                      the latest version from the Internet, if
                                      none is given.
      --no-release-uncompressing    Don't uncompress the downloaded release
                                      file
      --verbose <verbose level>     Set the verbose output level.
                                      0 - quiet; 1 error; 2 - warning;
                                      3 - normal; 4 - debug.
"
}

function do_parse_command() {
	if [ -z "$1" ]
	then
		return
	fi

	local CMD
	CMD="$1"

	case "${CMD}" in
		debug)
			# Debug.
			_CMD="do_debug"
			;;
		showver)
			# Show version.
			_CMD="do_print_version"
			;;
		showhelp)
			# Show help.
			_CMD="do_print_help"
			;;
		showinst)
			# Show meta information of a MyBB instance.
			_CMD="cmd_showinst"
			;;
		verifyinst)
			# Verify an installed MyBB instance.
			_CMD=""
			;;
		showrlsinfo)
			# Get and show meta information of a MyBB release.
			_CMD="cmd_showrlsinfo"
			;;
		getrls)
			# Download a MyBB release and extrace.
			_CMD="cmd_getrls"
			;;
		install)
			# Install a MyBB release.
			_CMD="cmd_install"
			;;
		remove)
			# Remove a MyBB instance.
			_CMD="cmd_remove"
			;;
		backup)
			# Bakcup a MyBB instance.
			_CMD="cmd_backup"
			;;
		restore)
			# Restore a MyBB instance from a backup.
			_CMD=""
			;;
		update)
			# Update a MyBB instance.
			_CMD="cmd_update"
			;;
		*)
			echo "${_SCRIPT_NAME} ${_SCRIPT_VER}: unknown command '${CMD}'."
			do_print_usage
			do_exit 1
			;;
	esac

	shift
	do_parse_options "${@}"
}

function do_parse_options() {
	if [ -z "$1" ]
	then
		return
	fi

	local i=1
	while [ ${#} -gt 0 ]
	do
		case "$1" in
			-h | --help)
				# Show help.
				_CMD="do_print_help"
				;;
			-v | --version)
				# Show help.
				_CMD="do_print_version"
				;;
			--show-instance)
				# Show meta information of a MyBB instance.
				_CMD="cmd_showinst"
				;;
			--show-release-info)
				# Get and show meta information of a MyBB release.
				_CMD="cmd_showrlsinfo"
				;;
			--get-release)
				# Download a MyBB release and extrace.
				_CMD="cmd_getrls"
				;;
			--install)
				# Install a MyBB release.
				_CMD="cmd_install"
				;;
			--remove)
				# Remove a MyBB instance.
				_CMD="cmd_remove"
				;;
			--backup)
				# Bakcup an installed MyBB instance.
				_CMD="cmd_backup"
				;;
			--update)
				# Update a MyBB instance.
				_CMD="cmd_update"
				;;
			-i | --instance-dir)
				if [ -z "$2" ] || _starts_with "$2" "-"
				then
					do_print_msg 'error' "You didn't specify the path for a MyBB instance."
					do_exit 1
				fi
				MYBB_INST_ROOT_INPUT="$2"
				shift
				;;
			-w | --working-dir)
				if [ -z "$2" ] || _starts_with "$2" "-"
				then
					do_print_msg 'error' "You didn't specify the path for the working directory."
					do_exit 1
				fi
				MYBB_UTILITY_WORKFOLDER_INPUT="$2"
				shift
				;;
			--release-ver)
				if [ -z "$2" ] || _starts_with "$2" "-"
				then
					do_print_msg 'error' "You didn't specify the version code (or 'latest' for the latest version) for a MyBB release."
					do_exit 1
				fi
				MYBB_TARGET_RELEASE_VERCODE_INPUT="$2"
				shift
				;;
			--no-release-uncompressing)
				MYBB_RELEASE_UNCOMPRESS=0
				;;
			--verbose)
				if [ -z "$2" ] || _starts_with "$2" "-"
				then
					MYBB_UTILITY_VERBOSE_LEVEL=4
				elif [ -n "$2" ] && [[ "$2" =~ ^[0-4]$ ]]
				then
					MYBB_UTILITY_VERBOSE_LEVEL="$2"
					shift
				else
					do_print_msg 'error' "Only one digit in '0, 1, 2, 3, 4' is allowed for the verbose level."
					do_exit 1
				fi
				;;
			*)
				do_print_msg 'error' "Unknown command or parameter '$1'."
				echo
				do_print_usage
				do_exit 1
				;;
		esac
		shift
	done
}

_CHECKED_CONNECTION=0
_CHECKED_RLS_VERCODE_INPUT=0
_CHECKED_RLS_VERCODE=0
_CHECKED_INSTDIR_INPUT=0
_CHECKED_INSTDIR=0
_CHECKED_INSTDIR_WPERM=0
_CHECKED_WORKDIR=0
_CHECKED_WORKDIR_WPERM=0

function do_preprocess() {
	local all_checks=(instdir instdir_wperm workdir workdir_wperm)

	local check_connection=1
	local check_rls_vercode=0
	local check_instdir_input=0
	local check_instdir_wperm=0
	local check_workdir_input=0
	local check_workdir_wperm=0

	local CMD="${_CMD}"

	case "${CMD}" in
		do_print_help)
			check_connection=0
			;;
		do_print_version)
			check_connection=0
			;;
		cmd_showinst)
			check_instdir_input=1
			;;
		cmd_verifyinst)
			check_instdir_input=1
			;;
		cmd_showrlsinfo)
			check_rls_vercode=1
			;;
		cmd_getrls)
			check_rls_vercode=1
			check_workdir_input=1
			check_workdir_wperm=1
			;;
		cmd_install)
			check_rls_vercode=1
			check_instdir_input=1
			check_instdir_wperm=1
			check_workdir_input=1
			check_workdir_wperm=1
			;;
		cmd_remove)
			check_instdir_input=1
			check_instdir_wperm=1
			check_workdir_input=1
			check_workdir_wperm=1
			;;
		cmd_backup)
			check_instdir_input=1
			check_workdir_input=1
			check_workdir_wperm=1
			;;
		cmd_restore)
			check_instdir_wperm=1
			;;
		cmd_update)
			check_rls_vercode=1
			check_instdir_input=1
			check_instdir_wperm=1
			check_workdir_input=1
			check_workdir_wperm=1
			;;
		*)
			;;
	esac

	# Check connection.
	if [ ${check_connection} -eq 1 ]
	then
		local respond=$(wget -S --spider "${MYBB_URL}" 2>&1 >/dev/null)
		if [[ "${respond}" =~ ([[:blank:]]*HTTP/1.1\ 200\ OK) ]]
		then
			_CHECKED_CONNECTION=1
		fi
	fi

	# Check MyBB release version code.
	# _CHECKED_RLS_VERCODE_INPUT
	if [ ${check_rls_vercode} -eq 1 ]
	then
		if [ -z "${MYBB_TARGET_RELEASE_VERCODE_INPUT}" ]
		then
			do_print_msg 'error' "You didn't specify the version code for a MyBB release. (--release-ver <ver.code>)"
			do_exit 1
		fi

		local MYBB_RELEASE_VERCODE_LATEST=1899

		if [ ${_CHECKED_CONNECTION} -eq 1 ] && [ -z "${MYBB_LATEST_NAME}" ]
		then
			_cmd_getlatestrlsinfo
		fi

		if [ -n "${MYBB_LATEST_VERCODE}" ]
		then
			MYBB_RELEASE_VERCODE_LATEST=${MYBB_LATEST_VERCODE}
		fi

		# or ^-?[0-9]+$
		if [ "${MYBB_TARGET_RELEASE_VERCODE_INPUT}" == "latest" ] && [ -n "${MYBB_LATEST_VERCODE}" ]
		then
			MYBB_TARGET_RELEASE_VERCODE="${MYBB_LATEST_VERCODE}"
		elif [[ "${MYBB_TARGET_RELEASE_VERCODE_INPUT}" =~ ^[[:digit:]]*$ ]] && [ ${MYBB_TARGET_RELEASE_VERCODE_INPUT} -ge 1800 ] && [ ${MYBB_TARGET_RELEASE_VERCODE_INPUT} -le ${MYBB_RELEASE_VERCODE_LATEST} ]
		then
			MYBB_TARGET_RELEASE_VERCODE="${MYBB_TARGET_RELEASE_VERCODE_INPUT}"
		else
			do_print_msg 'error' "You didn't correctly specify the version code for a MyBB release."
			do_exit 1
		fi

		_CHECKED_RLS_VERCODE_INPUT=1
	fi

	# Check the instance directory existence.
	# _CHECKED_INSTDIR_INPUT
	if [ ${check_instdir_input} -eq 1 ]
	then
		if [ -z "${MYBB_INST_ROOT_INPUT}" ]
		then
			do_print_msg 'info' "You didn't specify the path for a MyBB instance, current directory will be used."
			MYBB_INST_ROOT="."
		else
			MYBB_INST_ROOT="${MYBB_INST_ROOT_INPUT}"
		fi

		if [ "${CMD}" == "cmd_install" ]
		then
			if [ -f "${MYBB_INST_ROOT}" ]
			then
				do_print_msg 'error' "You've specified a file path for MyBB installation destination: ${MYBB_INST_ROOT}"
				do_exit 1
			fi

			if [ -d "${MYBB_INST_ROOT}" ]
			then
				do_print_msg 'warn' "The path you've specified for MyBB installation destination already exists: ${MYBB_INST_ROOT}"
			fi
		else
			if [ ! -d "${MYBB_INST_ROOT}" ]
			then
				do_print_msg 'error' "The directory specified for a MyBB instance doesn't exist: ${MYBB_INST_ROOT}"
				do_exit 1
			fi

			MYBB_INST_ROOT=$(do_get_abspath "${MYBB_INST_ROOT}")
			if [ $? -eq 127 ]
			then
				do_print_msg 'error' "Can't get the absolute path for the path specified for a MyBB instance."
				do_exit 1
			fi

			if [ ! -s "${MYBB_INST_ROOT}/${_MYBB_CLASS_FILE}" ]
			then
				do_print_msg 'error' "Can't find the MyBB class define file or the file has 0 length: ${MYBB_INST_ROOT}/${_MYBB_CLASS_FILE}"
				do_print_msg 'error' "Can't find any MyBB instance at: ${MYBB_INST_ROOT}"
				do_exit 1
			fi

			_CHECKED_INSTDIR_INPUT=1
		fi
	fi

	# Check the working directory permission.
	# _CHECKED_INSTDIR_WPERM
	if [ ${check_instdir_wperm} -eq 1 ]
	then
		if [ "${CMD}" == "cmd_install" ]
		then
			if [ ! -d "${MYBB_INST_ROOT}" ]
			then
				_cmd_preparedir "${MYBB_INST_ROOT}" "installation directory"
			fi
			if [ ! -d "${MYBB_INST_ROOT}" ]
			then
				do_print_msg 'error' "Can't create MyBB installation directory: ${MYBB_INST_ROOT}"
				do_exit 1
			fi
			MYBB_INST_ROOT=$(do_get_abspath "${MYBB_INST_ROOT}")
			if [ $? -eq 127 ]
			then
				do_print_msg 'error' "Can't get the absolute path for the path specified for a MyBB instance."
				do_exit 1
			fi
		fi

		local test_file="${MYBB_INST_ROOT}/~mybb_utility_${_DATE_NOW}.test"
		local test_file_c="test"
		touch "${test_file}" 2>&1 >/dev/null
		if [ -f "${test_file}" ]
		then
			echo "${test_file_c}" > "${test_file}" 2>/dev/null
			local test_file_c_r=$(cat "${test_file}" 2>/dev/null)
			if [ "${test_file_c_r}" == "${test_file_c}" ]
			then
				rm -f "${test_file}"
				_CHECKED_INSTDIR_WPERM=1
			else
				rm -f "${test_file}"
				do_print_msg 'error' "The MyBB instance directory isn't writable: ${MYBB_INST_ROOT}"
				do_exit 1
			fi
		else
			do_print_msg 'error' "Can't check if the MyBB instance directory is writable: ${MYBB_INST_ROOT}"
			do_exit 1
		fi
	fi

	# Check the working directory.
	# _CHECKED_WORKDIR
	if [ ${check_workdir_input} -eq 1 ]
	then
		if [ -z "${MYBB_UTILITY_WORKFOLDER_INPUT}" ]
		then
			do_print_msg 'info' "You didn't specify the path for the working directory, current directory will be used."
			MYBB_UTILITY_WORKFOLDER="$(pwd)"
		else
			MYBB_UTILITY_WORKFOLDER="${MYBB_UTILITY_WORKFOLDER_INPUT}"
		fi

		if [ ! -d "${MYBB_UTILITY_WORKFOLDER}" ] && [ -f "${MYBB_UTILITY_WORKFOLDER}" ]
		then
			do_print_msg 'error' "The path you specified for the working directory is a file: ${MYBB_UTILITY_WORKFOLDER}"
			do_exit 1
		fi

		if [ ! -d "${MYBB_UTILITY_WORKFOLDER}" ]
		then
			mkdir -p "${MYBB_UTILITY_WORKFOLDER}" 2>&1 >/dev/null
			if [ $? -eq 0 ] && [ -d "${MYBB_UTILITY_WORKFOLDER}" ]
			then
				do_print_msg 'info' "The working directory is created: ${MYBB_UTILITY_WORKFOLDER}"
			else
				do_print_msg 'error' "Can't create the working directory: ${MYBB_UTILITY_WORKFOLDER}"
				do_exit 1
			fi
		fi

		MYBB_UTILITY_WORKFOLDER=$(do_get_abspath "${MYBB_UTILITY_WORKFOLDER}")
		if [ $? -eq 127 ]
		then
			do_print_msg 'error' "Can't get the absolute path for the the working directory."
			do_exit 1
		fi

		_CHECKED_WORKDIR=1
	fi

	# Check the working directory permission.
	# _CHECKED_WORKDIR_WPERM
	if [ ${check_workdir_wperm} -eq 1 ]
	then
		local test_file="${MYBB_UTILITY_WORKFOLDER}/~mybb_utility_${_DATE_NOW}.test"
		local test_file_c="test"
		touch "${test_file}" 2>&1 >/dev/null
		if [ -f "${test_file}" ]
		then
			echo "${test_file_c}" > "${test_file}" 2>/dev/null
			local test_file_c_r=$(cat "${test_file}" 2>/dev/null)
			if [ "${test_file_c_r}" == "${test_file_c}" ]
			then
				rm -f "${test_file}"
				_CHECKED_WORKDIR_WPERM=1
			else
				rm -f "${test_file}"
				do_print_msg 'error' "The working directory isn't writable: ${MYBB_UTILITY_WORKFOLDER}"
				do_exit 1
			fi
		else
			do_print_msg 'error' "Can't check if the working directory is writable: ${MYBB_UTILITY_WORKFOLDER}"
			do_exit 1
		fi
	fi

	if [ ${_CHECKED_WORKDIR} -eq 1 ]
	then
		MYBB_UTILITY_WORKFOLDER_ROOT=${MYBB_UTILITY_WORKFOLDER_ROOT//\{MYBB_UTILITY_WORKFOLDER\}/"${MYBB_UTILITY_WORKFOLDER}"}
		MYBB_UTILITY_WORKFOLDER_BAK=${MYBB_UTILITY_WORKFOLDER_BAK//\{MYBB_UTILITY_WORKFOLDER_ROOT\}/"${MYBB_UTILITY_WORKFOLDER_ROOT}"}
		MYBB_UTILITY_WORKFOLDER_NEW_BASE=${MYBB_UTILITY_WORKFOLDER_NEW_BASE//\{MYBB_UTILITY_WORKFOLDER_ROOT\}/"${MYBB_UTILITY_WORKFOLDER_ROOT}"}
		MYBB_UTILITY_RELEASE_DOWNLOADED_BASE=${MYBB_UTILITY_RELEASE_DOWNLOADED_BASE//\{MYBB_UTILITY_WORKFOLDER_ROOT\}/"${MYBB_UTILITY_WORKFOLDER_ROOT}"}
		MYBB_UTILITY_RELEASE_CHECKSUMS_BASE=${MYBB_UTILITY_RELEASE_CHECKSUMS_BASE//\{MYBB_UTILITY_WORKFOLDER_ROOT\}/"${MYBB_UTILITY_WORKFOLDER_ROOT}"}
	fi
}


function do_main() {
	if [ -z "$1" ]
	then
		do_print_usage
		do_exit 1
	fi

	local arg
	arg="$1"
	if [ "${arg: 0: 1}" == "-" ]
	then
		do_parse_options "$@"
	else
		do_parse_command "$@"
	fi

	do_preprocess

	if [ -n "${_CMD}" ]
	then
		"${_CMD}"
	fi
}

function do_exit() {
	if [ -n "$1" ]
	then
		_EXIT_CODE="$1"
	fi

	exit "${_EXIT_CODE}"
}

MYBB_INST_ROOT_INPUT=""
MYBB_INST_ROOT=""
MYBB_INST_CLASS_FILE=""
MYBB_INST_VER=""
MYBB_INST_VERCODE=""

function _cmd_probeinst() {
	local MYBB_INST_CLASS_FILE="${MYBB_INST_ROOT}/${_MYBB_CLASS_FILE}"

	# The ending $'\n' in the pattern will result in a newline
	# [[ "$s" =~ [[:blank:]]*(public)[[:blank:]]*(\$[^\;[:blank:]]*)[[:blank:]]*=[[:blank:]]*([^$'\n']*)\;$'\n' ]] && for i in "${BASH_REMATCH[@]}";do echo "'$i'";done
	# [[ "$s" =~ [[:blank:]]*(public)[[:blank:]]*(\$version_code)[[:blank:]]*=[[:blank:]]*([[:digit:]]*).* ]] && for i in "${BASH_REMATCH[@]}";do echo "$i";done

	local found=0
	local found_mybb_class=""
	local found_ver=""
	local found_vercode_translated=""
	local found_vercode=""
	local num_lines=0
	while IFS= read -r fileline
	do
		(( num_lines += 1 ))
		# Try to find MyBB class define.
		#local pattern='[[:blank:]]*class[[:blank:]]*(MyBB)[[:blank:]]*\{[^'$'\n'']*'
		if [ $(( found & 1 )) ] && [[ "${fileline}" =~ [[:blank:]]*class[[:blank:]]*(MyBB)[[:blank:]]*\{[^$'\n']* ]]
		then
			found=$(( found | 1 ))
			found_mybb_class="${BASH_REMATCH[1]}"
		fi
		# Try to find MyBB version string.
		if [ $(( found & 2 )) ] && [[ "${fileline}" =~ [[:blank:]]*public[[:blank:]]*\$version[[:blank:]]*=[[:blank:]]*([^$'\n']*)\; ]]
		then
			found=$(( found | 2 ))
			found_ver="${BASH_REMATCH[1]}"
			found_ver="${found_ver#\"}"
			found_ver="${found_ver%\"}"
			found_vercode_translated="${found_ver//./}"
		fi
		# Try to find MyBB version code.
		if [ $(( found & 4 )) ] && [[ "${fileline}" =~ [[:blank:]]*public[[:blank:]]*\$version_code[[:blank:]]*=[[:blank:]]*([[:digit:]]*)[^$'\n']* ]]
		then
			found=$(( found | 4 ))
			found_vercode="${BASH_REMATCH[1]}"
		fi
		if [ ${found} -eq 7 ]
		then
			break
		fi
	done < "${MYBB_INST_CLASS_FILE}"

	#do_print_msg 'debugvar' '${MYBB_INST_ROOT}' "${MYBB_INST_ROOT}" '${num_lines}' "${num_lines}" '${found}' "${found}" '${found_mybb_class}' "${found_mybb_class}" '${found_ver}' "${found_ver}" '${found_vercode_translated}' "${found_vercode_translated}" '${found_vercode}' "${found_vercode}"
	#exit

	if [ ${found} -eq 7 ] && [ "${found_vercode_translated}" == "${found_vercode}" ]
	then
		MYBB_INST_VER="${found_ver}"
		MYBB_INST_VERCODE="${found_vercode}"
		_CHECKED_INSTDIR=1
	fi
}

function cmd_showinst() {
	_cmd_probeinst

	if [ ${_CHECKED_INSTDIR} -eq 1 ]
	then
		do_print_msg 'info' "A MyBB instance is detected in ${MYBB_INST_ROOT}, possibly:"
		do_print_msg 'info' "  Version code = ${MYBB_INST_VERCODE}"
		do_print_msg 'info' "       Version = ${MYBB_INST_VER}"
	else
		do_print_msg 'info' "Can't be sure if a MyBB instance is located at ${MYBB_INST_ROOT}"
	fi
}

MYBB_LATEST_NAME=""
MYBB_LATEST_VERSION=""
MYBB_LATEST_VERCODE=""
MYBB_LATEST_DATE=""
MYBB_LATEST_SIZE=""
MYBB_LATEST_DOWNLOAD_URL=""

MYBB_TARGET_RELEASE_VERCODE_INPUT=""
MYBB_TARGET_RELEASE_VERCODE=""

MYBB_RELEASE_NAME=""
MYBB_RELEASE_VERSION=""
MYBB_RELEASE_VERCODE=""
MYBB_RELEASE_DATE=""
MYBB_RELEASE_SIZE=""
MYBB_RELEASE_DOWNLOAD_URL=""
MYBB_RELEASE_UNCOMPRESS=1

# Usage: %0
# Get the latest MyBB release meta information
function _cmd_getlatestrlsinfo() {
	do_print_msg 'debugmsg' "Getting the latest MyBB 1.8 release meta information..."

	local MYBB_VER_CHECK_URL="${MYBB_VER_CHECK_URL_BASE}"
	local MYBB_VER_CHECK_PAGE=$(wget -qO- "${MYBB_VER_CHECK_URL}")
	MYBB_LATEST_NAME=$(do_get_release_xml_matched_by_tag "${MYBB_VER_CHECK_PAGE}" "friendly_name")
	if [ -n "${MYBB_LATEST_NAME}" ]
	then
		MYBB_LATEST_VERSION=$(do_get_release_xml_matched_by_tag "${MYBB_VER_CHECK_PAGE}" "latest_version")
		MYBB_LATEST_VERCODE=$(do_get_release_xml_matched_by_tag "${MYBB_VER_CHECK_PAGE}" "version_code")
		MYBB_LATEST_DATE=$(do_get_release_xml_matched_by_tag "${MYBB_VER_CHECK_PAGE}" "release_date")
		MYBB_LATEST_SIZE=$(do_get_release_xml_matched_by_tag "${MYBB_VER_CHECK_PAGE}" "download_size")
		MYBB_LATEST_DOWNLOAD_URL=$(do_get_release_xml_matched_by_tag "${MYBB_VER_CHECK_PAGE}" "download_url")
	fi
}

# Usage: $0 $1
# Get the meta information of MyBB of version code ($1).
function _cmd_getrlsinfo() {
	local MYBB_TARGET_RELEASE_VERCODE="$1"

	do_print_msg 'debugmsg' "Getting MyBB (${MYBB_TARGET_RELEASE_VERCODE}) meta information..."
	do_print_msg 'info' "Still working on getting a specific MyBB 1.8 release meta information."
}

# Usage: $0 $1
# Show the meta information of MyBB of version code ($1, or "latest"), latest version's retrieved if neither $1 or $MYBB_RELEASE_VERCODE is not given.
function _cmd_showrlsinfo() {
	local MYBB_TARGET_RELEASE_VERCODE="$1"

	if [ "${MYBB_TARGET_RELEASE_VERCODE}" == "latest" ]
	then
		if [ ${_CHECKED_CONNECTION} -eq 1 ]
		then
			_cmd_getlatestrlsinfo
			MYBB_RELEASE_NAME="${MYBB_LATEST_NAME}"
			MYBB_RELEASE_VERSION="${MYBB_LATEST_VERSION}"
			MYBB_RELEASE_VERCODE="${MYBB_LATEST_VERCODE}"
			MYBB_RELEASE_DATE="${MYBB_LATEST_DATE}"
			MYBB_RELEASE_SIZE="${MYBB_LATEST_SIZE}"
			MYBB_RELEASE_DOWNLOAD_URL="${MYBB_LATEST_DOWNLOAD_URL}"
			do_print_msg 'info' "[MYBB_RELEASE] ${MYBB_RELEASE_NAME} is the latest release:"
			do_print_msg 'info' "[MYBB_RELEASE]      Version = ${MYBB_RELEASE_VERSION}"
			do_print_msg 'info' "[MYBB_RELEASE] Version code = ${MYBB_RELEASE_VERCODE}"
			do_print_msg 'info' "[MYBB_RELEASE] Release date = ${MYBB_RELEASE_DATE}"
			do_print_msg 'info' "[MYBB_RELEASE]    File size = ${MYBB_RELEASE_SIZE}"
			do_print_msg 'info' "[MYBB_RELEASE]     File URL = ${MYBB_RELEASE_DOWNLOAD_URL}"
		else
			do_print_msg 'info' "Can't reach MyBB server to fetch the latest release information."
		fi
	else
		_cmd_getrlsinfo "${MYBB_TARGET_RELEASE_VERCODE}"
		# do_print_msg 'info' "[MYBB_RELEASE] ${MYBB_RELEASE_NAME} meta info.:"
	fi
}

# Usage: $0
# Show the meta information of a MyBB release.
function cmd_showrlsinfo() {
	_cmd_showrlsinfo "${MYBB_TARGET_RELEASE_VERCODE_INPUT}"
}

MYBB_UTILITY_WORKFOLDER_INPUT=""
MYBB_UTILITY_WORKFOLDER=""
MYBB_UTILITY_WORKFOLDER_ROOT="{MYBB_UTILITY_WORKFOLDER}/mybb_utility_${_DATE_NOW}"
MYBB_UTILITY_WORKFOLDER_BAK="{MYBB_UTILITY_WORKFOLDER_ROOT}/backup_mybb_{MYBB_VERCODE}"
MYBB_UTILITY_WORKFOLDER_NEW_BASE="{MYBB_UTILITY_WORKFOLDER_ROOT}/release_mybb_{MYBB_VERCODE}"
MYBB_UTILITY_WORKFOLDER_NEW=""
MYBB_UTILITY_RELEASE_DOWNLOADED_BASE="{MYBB_UTILITY_WORKFOLDER_ROOT}/release_mybb_{MYBB_VERCODE}.zip"
MYBB_UTILITY_RELEASE_DOWNLOADED=""
MYBB_UTILITY_RELEASE_CHECKSUMS_BASE="{MYBB_UTILITY_WORKFOLDER_ROOT}/checksums_{MYBB_VERCODE}.txt"
MYBB_UTILITY_RELEASE_CHECKSUMS=""

# Usage: $0 $1 $2
# $1 directory path
# $2 directory description
function _cmd_preparedir() {
	local dir_path="$1"
	local desc="$2"
	if [ ! -d "${dir_path}" ]
	then
		mkdir -p "${dir_path}" 2>&1 >/dev/null
		if [ -d "${dir_path}" ]
		then
			do_print_msg 'info' "Directory created (${desc}): ${dir_path}"
		else
			do_print_msg 'error' "Can't created the directory (${desc}): ${dir_path}"
			do_exit 1
		fi
	fi
}

# Usage: $0 $1 $2
# Download a MyBB release of version code ($1). Extract the downloaded file ($2).
function _cmd_getrls() {
	local mybb_vercode="$1"
	local extract="$2"
	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_downlaod_url=${MYBB_DOWNLOAD_URL_BASE//\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_downloaded=${MYBB_UTILITY_RELEASE_DOWNLOADED_BASE//\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_extraced=${MYBB_UTILITY_WORKFOLDER_NEW_BASE//\{MYBB_VERCODE\}/"${mybb_vercode}"}

	do_print_msg 'debugmsg' "Downloading MyBB ${mybb_ver} release file (${mybb_downlaod_url})..."
	do_download_url "${mybb_downlaod_url}" "${mybb_downloaded}"
	if [ -s "${mybb_downloaded}" ]
	then
		do_print_msg 'info' "Successfully downloaded MyBB ${mybb_ver}: ${mybb_downloaded}"
	else
		do_print_msg 'error' "Can't download the specific release file from ${mybb_downlaod_url}"
		exit
	fi

	#_cmd_verifyrls

	if [ ${extract} -eq 1 ]
	then
		# Test the downloaded file.
		do_print_msg 'debugmsg' "Testing the downloaded file (${mybb_downloaded})..."
		unzip -t "${mybb_downloaded}" 2>&1 >/dev/null
		if [ $? -eq 0 ]
		then
			do_print_msg 'info' "The downloaded file is successfully tested: ${mybb_downloaded}"
		else
			do_print_msg 'error' "The downloaded file has failed testing: ${mybb_downloaded}"
			exit
		fi

		_cmd_preparedir "${mybb_extraced}" "release directory"

		# Extract the downloaded file.
		do_print_msg 'debugmsg' "Extracting the downloaded file (${mybb_downloaded})..."
		unzip "${mybb_downloaded}" -d "${mybb_extraced}" 2>&1 >/dev/null
		if [ $? -eq 0 ]
		then
			do_print_msg 'info' "The release of MyBB ${mybb_ver} is extraced to ${mybb_extraced}/"
		else
			do_print_msg 'error' "Can't extract the downloaded release file of MyBB ${mybb_ver}: ${mybb_downloaded}"
			exit
		fi
	fi
}

# Usage: $0 $1 $2
# Verify a MyBB release ($2) of version code ($1) 
function _cmd_verifyrls() {
	local mybb_vercode="$1"
	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_release_url=${MYBB_RELEASE_URL_BASE/\{MYBB_VER\}/${mybb_vercode}}

	#MYBB_RELEASE_PAGE=$(do_download_url "${MYBB_RELEASE_URL}")

	#                                        <div class="download-packages__checksums_checksum">
	#                                            <p class="download-packages__checksums__type">sha512:</p>
	#                                            <p class="download-packages__checksums__value">f2d4b89e135e5061face78537c3d6f9bffad49ec6c87a29a7d007e354e5fd51f1742c7a242597bd26fab4499e2df52df66480ac1d97ebe79f04e21ade3399604</p>
	#                                        </div>
	local checksum="f2d4b89e135e5061face78537c3d6f9bffad49ec6c87a29a7d007e354e5fd51f1742c7a242597bd26fab4499e2df52df66480ac1d97ebe79f04e21ade3399604"
	# Disable file verification.
	#checksum="?"

	result=$(do_verify_file "${MYBB_UPGRADER_DOWNLOADED}" "sha512sum" "${checksum}")
	if [ ${MYBB_UPGRADER_IGNORE_CHECKSUM} -ne 1 ] && [ ${result: 0: 1} -eq 0 ]
	then
		do_print_msg 'debugmsg' "[MYBB_UPGRADER] ${MYBB_UPGRADER_DOWNLOADED}: the downloaded file has been verified."
	elif [ ${MYBB_UPGRADER_IGNORE_CHECKSUM} -ne 1 ] && [ ${result: 0: 1} -eq 1 ]
	then
		do_print_msg 'info' "[MYBB_UPGRADER] ${MYBB_UPGRADER_DOWNLOADED}: the verification (sha512sum) of the downloaded file has failed, aborted."
		do_print_msg 'info' "[MYBB_UPGRADER] ${MYBB_DOWNLOAD_URL}: the SHA-512 of the release file is"
		do_print_msg 'info' "                ${checksum}"
		do_print_msg 'info' "[MYBB_UPGRADER] ${MYBB_UPGRADER_DOWNLOADED}: the SHA-512 of the downloaded file is"
		do_print_msg 'info' "                ${result: 2}"
		exit
	elif [ "${result: 0: 1}" == "?" ]
	then
		do_print_msg 'info' "[MYBB_UPGRADER] ${MYBB_UPGRADER_DOWNLOADED}: the verification (sha512sum) is ignored, you may verify it yourself. The SHA-512 of it is"
		do_print_msg 'info' "                ${checksum}"
	fi
}

function cmd_getrls() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach MyBB server to download the release file."
		do_exit 1
	fi

	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_ROOT}" "working root"

	MYBB_UTILITY_WORKFOLDER_NEW=${MYBB_UTILITY_WORKFOLDER_NEW_BASE//\{MYBB_VERCODE\}/"${MYBB_TARGET_RELEASE_VERCODE}"}
	MYBB_UTILITY_RELEASE_DOWNLOADED=${MYBB_UTILITY_RELEASE_DOWNLOADED_BASE//\{MYBB_VERCODE\}/"${MYBB_TARGET_RELEASE_VERCODE}"}

	_cmd_getrls "${MYBB_TARGET_RELEASE_VERCODE}" "${MYBB_RELEASE_UNCOMPRESS}"
}

# $0 $1 $2
# $1 version code
# $2 (optional) download location
function _cmd_get_checksums() {
	local mybb_vercode="$1"
	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_checksums_url=${MYBB_RELEASE_CHECKSUMS_URL_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_checksums_path=${MYBB_UTILITY_RELEASE_CHECKSUMS_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}

	if [ -n "$2" ]
	then
		mybb_checksums_path=$2
	fi

	do_download_url "${mybb_checksums_url}" "${mybb_checksums_path}"
	if [ -s "${mybb_checksums_path}" ]
	then
		do_print_msg 'debugmsg' "The checksums for MyBB ${mybb_ver} (${mybb_vercode}) is downloaded to ${mybb_checksums_path}"
		return 0
	else
		do_print_msg 'info' "Can't download the checksums for MyBB ${mybb_ver} (${mybb_vercode}) (${mybb_checksums_url})."
		return 1
	fi
}

# $0 $1 $2 $3 $4
# $1 new release version code
# $2 release directory
# $3 MyBB instance directory
# $4 ignore 'no touch list', 0 will respect the no touch list, 1 will neglect the list.
function _cmd_install() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'info' "Can't reach '${MYBB_COM}' to fetch the release checksums, and hence can't determine which file(s) to install."
	fi

	local mybb_vercode="$1"
	local mybb_release_dir="$2"
	local mybb_destination_dir="$3"
	local ignore_no_touch_list="$4"

	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_checksums_url=${MYBB_RELEASE_CHECKSUMS_URL_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_checksums_path=${MYBB_UTILITY_RELEASE_CHECKSUMS_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}

	local checksum path result skip_current_file
	local i j

	_cmd_get_checksums "${mybb_vercode}" "${mybb_checksums_path}" 2>&1 >/dev/null
	if [ $? -eq 1 ] || [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach '${MYBB_COM}' or can't download the checksums for MyBB ${mybb_ver} (${mybb_checksums_url})."
		do_exit 1
	fi

	do_print_msg 'debugmsg' "Processing the list of files for install..."

	if [ ${ignore_no_touch_list} -ne 1 ] && [ ${#MYBB_UTILITY_NO_TOUCH_LIST[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#MYBB_UTILITY_NO_TOUCH_LIST[@]} file(s) and/or folder(s) are excluded from install:"
		for i in "${MYBB_UTILITY_NO_TOUCH_LIST[@]}"
		do
			do_print_msg 'info' "  ${i}"
		done
	fi

	# Other ways to get the file path in each checksum line:
	# path=${line#* }
	# [[ "$line" =~ [[:space:]].([[:print:]]*) ]] && path=${BASH_REMATCH[1]}

	while IFS=' ' read -r checksum path
	do
		if [ "${path: 0: 2}" == "./" ]
		then
			#i="${MYBB_ROOT}/${i: 2}"
			_MYBB_FILELIST_NEW+=("${path}")
		fi
	done < "${mybb_checksums_path}"

	result=""
	for i in "${_MYBB_FILELIST_NEW[@]}"
	do
		if [ -z "${result}" ]
		then
			result="${i}"
		else
			result=$(echo -e "${result}\n${i}")
		fi
	done
	result=$(echo "${result}" | sort -u)

	_MYBB_FILELIST_NEW=()
	while IFS= read -r path
	do
		if [ -n "${path}" ]
		then
			_MYBB_FILELIST_NEW+=("${path}")
		fi
	done <<< $(echo "${result}")

	if [ ${#_MYBB_FILELIST_NEW[*]} -gt 0 ]
	then
		do_print_msg 'debugmsg' "Copying ${#_MYBB_FILELIST_NEW[*]} files of MyBB ${mybb_ver} to the MyBB instance (${mybb_destination_dir})..."
		cd "${mybb_release_dir}/Upload"
		for i in "${_MYBB_FILELIST_NEW[@]}"
		do
			skip_current_file=0

			if [ ${ignore_no_touch_list} -ne 1 ]
			then
				for j in "${MYBB_UTILITY_NO_TOUCH_LIST[@]}"
				do
					if [ "${j: -1}" == "/" ] && [ "${i: 0: ${#j}}" == "${j}" ] || [ "${j}" == "${i}" ]
					then
						skip_current_file=1
						_MYBB_FILELIST_NOT_UPDATED+=("${i}")
						break
					fi
				done
			fi

			if [ ${skip_current_file} -eq 0 ]
			then
				cp --parent --preserve "${i}" "${mybb_destination_dir}"
				if [ $? -eq 0 ]
				then
					_MYBB_FILELIST_UPDATED+=("${i}")
				else
					_MYBB_FILELIST_NOT_UPDATED+=("${i}")
				fi
			fi
		done
		cd "${_CURRENT_DIR}"
	fi

	do_print_msg 'info' "Copied ${#_MYBB_FILELIST_UPDATED[@]} new file(s) to the MyBB instance (${mybb_destination_dir})..."
	if [ ${#_MYBB_FILELIST_NOT_UPDATED[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#_MYBB_FILELIST_NOT_UPDATED[@]} new file(s) were not copied to the MyBB instance:"
		for i in "${_MYBB_FILELIST_NOT_UPDATED[@]}"
		do
			do_print_msg 'info' "  ${mybb_release_dir}/Upload/${i: 2}"
		done
	fi
}

function cmd_install() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach MyBB server to download the release file."
		do_exit 1
	fi

	local MYBB_INST_CLASS_FILE="${MYBB_INST_ROOT}/${_MYBB_CLASS_FILE}"
	if [ -s "${MYBB_INST_CLASS_FILE}" ]
	then
		_cmd_probeinst
	fi

	if [ ${_CHECKED_INSTDIR} -eq 1 ]
	then
		do_print_msg 'info' "A MyBB instance is detected in ${MYBB_INST_ROOT}, possibly:"
		do_print_msg 'info' "  Version code = ${MYBB_INST_VERCODE}"
		do_print_msg 'info' "       Version = ${MYBB_INST_VER}"
		do_print_msg 'error' "Looks like there's already a MyBB instance located at ${MYBB_INST_ROOT}"
		do_exit 1
	fi

	if [ ! -d "${MYBB_INST_ROOT}" ] && [ ! -f "${MYBB_INST_ROOT}" ]
	then
		_cmd_preparedir "${MYBB_INST_ROOT}" "installation directory"
	fi

	local mybb_ver=$(echo "${MYBB_TARGET_RELEASE_VERCODE: 0 : 1}.${MYBB_TARGET_RELEASE_VERCODE: 1 : 1}.${MYBB_TARGET_RELEASE_VERCODE: 2}")
	do_print_msg 'info' "MyBB version to install: ${mybb_ver} (${MYBB_TARGET_RELEASE_VERCODE})"
	do_print_msg 'info' "Installation destination: ${MYBB_INST_ROOT}"

	MYBB_UTILITY_WORKFOLDER_NEW=${MYBB_UTILITY_WORKFOLDER_NEW_BASE//\{MYBB_VERCODE\}/"${MYBB_TARGET_RELEASE_VERCODE}"}
	MYBB_UTILITY_RELEASE_DOWNLOADED=${MYBB_UTILITY_RELEASE_DOWNLOADED_BASE//\{MYBB_VERCODE\}/"${MYBB_TARGET_RELEASE_VERCODE}"}

	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_ROOT}" "working root"

	_cmd_getrls "${MYBB_TARGET_RELEASE_VERCODE}" 1

	_cmd_install "${MYBB_TARGET_RELEASE_VERCODE}" "${MYBB_UTILITY_WORKFOLDER_NEW}" "${MYBB_INST_ROOT}" 1

	do_print_msg 'info' "MyBB file installation complete. Please check file/directory permissions."
	do_print_msg 'info' "Now you need to continue MyBB installation from your browser:"
	do_print_msg 'info' "  1. Assume 'https://example.com/forum' is the forum URL, please open"
	do_print_msg 'info' "     'https://example.com/forum/install/' in your browser and then follow"
	do_print_msg 'info' "     the instruction listed on the installation page."
}

_MYBB_FILELIST_NOW=()
_MYBB_FILELIST_BACKUP=()
_MYBB_FILELIST_SKIPPED_BACKUP=()

_MYBB_FILELIST_TO_REMOVE=()
_MYBB_FILELIST_REMOVED=()
_MYBB_FILELIST_NOT_REMOVED=()

# $0 $1 $2 $3 $4
# $1 version code
# $2 source directory
# $3 backup directory
# $4 ignore 'no touch list', 0 will respect the no touch list, 1 will neglect the list.
function _cmd_remove() {
	do_print_msg 'debugmsg' "Removing files..."

	local mybb_vercode="$1"
	local mybb_source_dir="$2"
	local mybb_bakcup_dir="$3"
	local ignore_no_touch_list="$4"

	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_checksums_url=${MYBB_RELEASE_CHECKSUMS_URL_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_checksums_path=${MYBB_UTILITY_RELEASE_CHECKSUMS_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}

	local checksum path result skip_current_file
	local i j

	_cmd_get_checksums "${mybb_vercode}" "${mybb_checksums_path}" 2>&1 >/dev/null
	if [ $? -eq 1 ] || [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach '${MYBB_COM}' or can't download the checksums for MyBB ${mybb_ver} (${mybb_checksums_url})."
		do_exit 1
	fi

	do_print_msg 'debugmsg' "Processing the list of files to remove..."

	if [ ${ignore_no_touch_list} -ne 1 ] && [ ${#MYBB_UTILITY_NO_TOUCH_LIST[@]} -gt 0 ]
	then
		do_print_msg 'info' "Entries of files/directories excluded from removal:"
		for i in "${MYBB_UTILITY_NO_TOUCH_LIST[@]}"
		do
			do_print_msg 'info' "  ${i}"
		done
	fi

	# Other ways to get the file path in each checksum line:
	# path=${line#* }
	# [[ "$line" =~ [[:space:]].([[:print:]]*) ]] && path=${BASH_REMATCH[1]}

	while IFS=' ' read -r checksum path
	do
		if [ "${path: 0: 2}" == "./" ]
		then
			#i="${MYBB_ROOT}/${i: 2}"
			_MYBB_FILELIST_TO_REMOVE+=("${path}")
		fi
	done < "${mybb_checksums_path}"

	result=""
	for i in "${_MYBB_FILELIST_TO_REMOVE[@]}"
	do
		if [ -z "${result}" ]
		then
			result="${i}"
		else
			result=$(echo -e "${result}\n${i}")
		fi
	done
	result=$(echo "${result}" | sort -u)

	_MYBB_FILELIST_TO_REMOVE=()
	while IFS= read -r path
	do
		if [ -n "${path}" ]
		then
			_MYBB_FILELIST_TO_REMOVE+=("${path}")
		fi
	done <<< $(echo "${result}")

	if [ ${#_MYBB_FILELIST_TO_REMOVE[*]} -gt 0 ]
	then
		do_print_msg 'debugmsg' "Removing ${#_MYBB_FILELIST_TO_REMOVE[*]} files of MyBB ${mybb_ver} (${mybb_vercode}) from the MyBB instance (${mybb_destination_dir})..."
		for i in "${_MYBB_FILELIST_TO_REMOVE[@]}"
		do
			skip_current_file=0

			if [ ${ignore_no_touch_list} -ne 1 ]
			then
				for j in "${MYBB_UTILITY_NO_TOUCH_LIST[@]}"
				do
					if [ "${j: -1}" == "/" ] && [ "${i: 0: ${#j}}" == "${j}" ] || [ "${j}" == "${i}" ]
					then
						skip_current_file=1
						_MYBB_FILELIST_NOT_REMOVED+=("${i}")
						break
					fi
				done
			fi

			if [ ${skip_current_file} -eq 0 ]
			then
				rm -f "${mybb_source_dir}/${i: 2}"
				if [ $? -eq 0 ]
				then
					_MYBB_FILELIST_REMOVED+=("${i}")
				else
					_MYBB_FILELIST_NOT_REMOVED+=("${i}")
				fi
			fi
		done
	fi

	if [ ${#_MYBB_FILELIST_NOT_REMOVED[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#_MYBB_FILELIST_NOT_REMOVED[@]} file(s) were not removed:"
		for i in "${_MYBB_FILELIST_NOT_REMOVED[@]}"
		do
			do_print_msg 'info' "  ${mybb_source_dir}/${i: 2}"
		done
	else
		do_print_msg 'info' "${#_MYBB_FILELIST_REMOVED[@]} file(s) were successfully removed from the MyBB instance (${mybb_source_dir})."
		do_print_msg 'info' "Empty directories, if any, were not removed."
	fi
}

function cmd_remove() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach '${MYBB_COM}' to fetch the release checksums, and hence can't determine which file(s) to remove."
		do_exit 1
	fi

	_cmd_probeinst

	if [ ${_CHECKED_INSTDIR} -ne 1 ]
	then
		do_print_msg 'error' "Can't be sure if a MyBB instance is located at ${MYBB_INST_ROOT}"
		do_exit 1
	fi

	do_print_msg 'info' "A MyBB instance is detected in ${MYBB_INST_ROOT}, possibly:"
	do_print_msg 'info' "  Version code = ${MYBB_INST_VERCODE}"
	do_print_msg 'info' "       Version = ${MYBB_INST_VER}"

	do_print_msg 'info' "The MyBB instance be removed file by file. Any empty directory will not be removed."

	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_ROOT}" "working root"

	_cmd_remove "${MYBB_INST_VERCODE}" "${MYBB_INST_ROOT}" "${MYBB_UTILITY_WORKFOLDER_BAK}" 0
}

# $0 $1 $2 $3
# $1 version code
# $2 source directory
# $3 backup directory
function _cmd_backup() {
	local mybb_vercode="$1"
	local mybb_source_dir="$2"
	local mybb_bakcup_dir="$3"

	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_checksums_url=${MYBB_RELEASE_CHECKSUMS_URL_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_checksums_path=${MYBB_UTILITY_RELEASE_CHECKSUMS_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}

	local checksum path result skip_current_file
	local i j

	_cmd_get_checksums "${mybb_vercode}" "${mybb_checksums_path}" 2>&1 >/dev/null
	if [ $? -eq 1 ] || [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach '${MYBB_COM}' or can't download the checksums for MyBB ${mybb_ver} (${mybb_checksums_url})."
		do_exit 1
	fi

	do_print_msg 'debugmsg' "Processing the list of files for backup..."

	if [ ${#MYBB_UTILITY_NO_BACKUP_LIST[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#MYBB_UTILITY_NO_BACKUP_LIST[@]} file(s) and/or folder(s) are excluded from backup:"
		for i in "${MYBB_UTILITY_NO_BACKUP_LIST[@]}"
		do
			do_print_msg 'info' "  ${i}"
		done
	fi

	# Other ways to get the file path in each checksum line:
	# path=${line#* }
	# [[ "$line" =~ [[:space:]].([[:print:]]*) ]] && path=${BASH_REMATCH[1]}

	while IFS=' ' read -r checksum path
	do
		if [ "${path: 0: 2}" == "./" ]
		then
			_MYBB_FILELIST_NOW+=("${path}")
		fi
	done < "${mybb_checksums_path}"

	result=""
	for i in "${_MYBB_FILELIST_NOW[@]}"
	do
		if [ -z "${result}" ]
		then
			result="${i}"
		else
			result=$(echo -e "${result}\n${i}")
		fi
	done
	result=$(echo "${result}" | sort -u)

	_MYBB_FILELIST_NOW=()
	while IFS= read -r path
	do
		if [ -n "${path}" ]
		then
			_MYBB_FILELIST_NOW+=("${path}")
		fi
	done <<< $(echo "${result}")

	if [ ${#_MYBB_FILELIST_NOW[*]} -gt 0 ]
	then
		do_print_msg 'debugmsg' "Copying ${#_MYBB_FILELIST_NOW[*]} files from MyBB ${mybb_ver} (${mybb_source_dir}) to the backup folder (${mybb_bakcup_dir})..."
		cd "${mybb_source_dir}"
		for i in "${_MYBB_FILELIST_NOW[@]}"
		do
			skip_current_file=0

			for j in "${MYBB_UTILITY_NO_BACKUP_LIST[@]}"
			do
				if [ "${j: -1}" == "/" ] && [ "${i: 0: ${#j}}" == "${j}" ] || [ "${j}" == "${i}" ]
				then
					skip_current_file=1
					_MYBB_FILELIST_SKIPPED_BACKUP+=("${i}")
					break
				fi
			done

			if [ ${skip_current_file} -eq 0 ]
			then
				cp --parent --preserve "${i}" "${mybb_bakcup_dir}"
				if [ $? -eq 0 ]
				then
					_MYBB_FILELIST_BACKUP+=("${i}")
				else
					_MYBB_FILELIST_SKIPPED_BACKUP+=("${i}")
				fi
			fi
		done
		cd "${_CURRENT_DIR}"
	fi

	do_print_msg 'info' "Copied ${#_MYBB_FILELIST_BACKUP[@]} file(s) from MyBB ${mybb_ver} (${mybb_source_dir}) to the backup folder (${mybb_bakcup_dir})."
	if [ ${#_MYBB_FILELIST_SKIPPED_BACKUP[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#_MYBB_FILELIST_SKIPPED_BACKUP[@]} file(s) were not backed up:"
		for i in "${_MYBB_FILELIST_SKIPPED_BACKUP[@]}"
		do
			do_print_msg 'info' "  ${mybb_source_dir}/${i: 2}"
		done
	fi
}

function cmd_backup() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach '${MYBB_COM}' to fetch the release checksums, and hence can't determine which file(s) to backup."
		do_exit 1
	fi

	_cmd_probeinst

	if [ ${_CHECKED_INSTDIR} -ne 1 ]
	then
		do_print_msg 'error' "Can't be sure if a MyBB instance is located at ${MYBB_INST_ROOT}"
		do_exit 1
	fi

	do_print_msg 'info' "A MyBB instance is detected in ${MYBB_INST_ROOT}, possibly:"
	do_print_msg 'info' "  Version code = ${MYBB_INST_VERCODE}"
	do_print_msg 'info' "       Version = ${MYBB_INST_VER}"

	do_print_msg 'debugmsg' "Taking backup of core files in current MyBB copy (${MYBB_INST_ROOT})..."

	MYBB_UTILITY_WORKFOLDER_BAK=${MYBB_UTILITY_WORKFOLDER_BAK//\{MYBB_VERCODE\}/"${MYBB_INST_VERCODE}"}
	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_ROOT}" "working root"
	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_BAK}" "backup folder"

	_cmd_backup "${MYBB_INST_VERCODE}" "${MYBB_INST_ROOT}" "${MYBB_UTILITY_WORKFOLDER_BAK}"
}

_MYBB_FILELIST_NEW=()
_MYBB_FILELIST_CREATED=()
_MYBB_FILELIST_UPDATED=()
_MYBB_FILELIST_NOT_UPDATED=()

# $0 $1 $2 $3 $4
# $1 new release version code
# $2 release directory
# $3 MyBB instance directory
# $4 ignore 'no touch list', 0 will respect the no touch list, 1 will neglect the list.
function _cmd_update() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'info' "Can't reach '${MYBB_COM}' to fetch the release checksums, and hence can't determine which file(s) to update."
	fi

	local mybb_vercode="$1"
	local mybb_release_dir="$2"
	local mybb_destination_dir="$3"
	local ignore_no_touch_list="$4"

	local mybb_ver=$(echo "${mybb_vercode: 0 : 1}.${mybb_vercode: 1 : 1}.${mybb_vercode: 2}")
	local mybb_checksums_url=${MYBB_RELEASE_CHECKSUMS_URL_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}
	local mybb_checksums_path=${MYBB_UTILITY_RELEASE_CHECKSUMS_BASE/\{MYBB_VERCODE\}/"${mybb_vercode}"}

	local checksum path result skip_current_file path_dir
	local i j

	_cmd_get_checksums "${mybb_vercode}" "${mybb_checksums_path}" 2>&1 >/dev/null
	if [ $? -eq 1 ] || [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach '${MYBB_COM}' or can't download the checksums for MyBB ${mybb_ver} (${mybb_checksums_url})."
		do_exit 1
	fi

	do_print_msg 'debugmsg' "Processing the list of files for install/update..."

	if [ ${ignore_no_touch_list} -ne 1 ] && [ ${#MYBB_UTILITY_NO_TOUCH_LIST[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#MYBB_UTILITY_NO_TOUCH_LIST[@]} file(s) and/or folder(s) are excluded from update:"
		for i in "${MYBB_UTILITY_NO_TOUCH_LIST[@]}"
		do
			do_print_msg 'info' "  ${i}"
		done
	fi

	# Other ways to get the file path in each checksum line:
	# path=${line#* }
	# [[ "$line" =~ [[:space:]].([[:print:]]*) ]] && path=${BASH_REMATCH[1]}

	while IFS=' ' read -r checksum path
	do
		if [ "${path: 0: 2}" == "./" ]
		then
			#i="${MYBB_ROOT}/${i: 2}"
			_MYBB_FILELIST_NEW+=("${path}")
		fi
	done < "${mybb_checksums_path}"

	result=""
	for i in "${_MYBB_FILELIST_NEW[@]}"
	do
		if [ -z "${result}" ]
		then
			result="${i}"
		else
			result=$(echo -e "${result}\n${i}")
		fi
	done
	result=$(echo "${result}" | sort -u)

	_MYBB_FILELIST_NEW=()
	while IFS= read -r path
	do
		if [ -n "${path}" ]
		then
			_MYBB_FILELIST_NEW+=("${path}")
		fi
	done <<< $(echo "${result}")

	if [ ${#_MYBB_FILELIST_NEW[*]} -gt 0 ]
	then
		do_print_msg 'debugmsg' "Copying ${#_MYBB_FILELIST_NEW[*]} files of MyBB ${mybb_ver} to the MyBB instance (${mybb_destination_dir})..."
		for i in "${_MYBB_FILELIST_NEW[@]}"
		do
			skip_current_file=0

			if [ ${ignore_no_touch_list} -ne 1 ]
			then
				for j in "${MYBB_UTILITY_NO_TOUCH_LIST[@]}"
				do
					if [ "${j: -1}" == "/" ] && [ "${i: 0: ${#j}}" == "${j}" ] || [ "${j}" == "${i}" ]
					then
						skip_current_file=1
						_MYBB_FILELIST_NOT_UPDATED+=("${i}")
						break
					fi
				done
			fi

			if [ ${skip_current_file} -eq 0 ]
			then
				if [ ! -f "${mybb_destination_dir}/${i: 2}" ]
				then
					_MYBB_FILELIST_CREATED+=("${mybb_destination_dir}/${i: 2}")

					path_dir="${i%/*}"
					path_dir="${path_dir: 2}"
					if [ ! -d "${mybb_destination_dir}/${path_dir}" ]
					then
						_cmd_preparedir "${mybb_destination_dir}/${path_dir}" "./${path_dir}"
					fi
				fi

				cat "${mybb_release_dir}/Upload/${i: 2}" > "${mybb_destination_dir}/${i: 2}" 2>/dev/null
				if [ $? -eq 0 ]
				then
					_MYBB_FILELIST_UPDATED+=("${i}")
				else
					_MYBB_FILELIST_NOT_UPDATED+=("${i}")
				fi
			fi
		done
	fi

	do_print_msg 'info' "${#_MYBB_FILELIST_UPDATED[@]} file(s) were updated in the MyBB instance (${mybb_destination_dir})..."

	if [ ${#_MYBB_FILELIST_CREATED[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#_MYBB_FILELIST_CREATED[@]} new file(s) were created in the MyBB instance:"
		for i in "${_MYBB_FILELIST_CREATED[@]}"
		do
			do_print_msg 'info' "  ${i}"
		done
	fi

	if [ ${#_MYBB_FILELIST_NOT_UPDATED[@]} -gt 0 ]
	then
		do_print_msg 'info' "${#_MYBB_FILELIST_NOT_UPDATED[@]} new file(s) were not copied to the MyBB instance:"
		for i in "${_MYBB_FILELIST_NOT_UPDATED[@]}"
		do
			do_print_msg 'info' "  ${mybb_release_dir}/Upload/${i: 2}"
		done
	fi
}

function cmd_update() {
	if [ ${_CHECKED_CONNECTION} -ne 1 ]
	then
		do_print_msg 'error' "Can't reach MyBB server to download the release file."
		do_exit 1
	fi

	_cmd_probeinst

	if [ ${_CHECKED_INSTDIR} -ne 1 ]
	then
		do_print_msg 'error' "Can't be sure if a MyBB instance is located at ${MYBB_INST_ROOT}"
		do_exit 1
	fi

	do_print_msg 'info' "A MyBB instance is detected in ${MYBB_INST_ROOT}, possibly:"
	do_print_msg 'info' "  Version code = ${MYBB_INST_VERCODE}"
	do_print_msg 'info' "       Version = ${MYBB_INST_VER}"

	if [ ${MYBB_TARGET_RELEASE_VERCODE} -le ${MYBB_INST_VERCODE} ]
	then
		do_print_msg 'warn' "The MyBB instance's version (${MYBB_INST_VERCODE}) is newer or equal to the specified version (${MYBB_TARGET_RELEASE_VERCODE})."
		do_print_msg 'warn' "To force the update action, please specify '--force-update'."
	fi

	local mybb_ver=$(echo "${MYBB_TARGET_RELEASE_VERCODE: 0 : 1}.${MYBB_TARGET_RELEASE_VERCODE: 1 : 1}.${MYBB_TARGET_RELEASE_VERCODE: 2}")
	do_print_msg 'info' "The MyBB instance will be updated to ${mybb_ver} (${MYBB_TARGET_RELEASE_VERCODE})."

	MYBB_UTILITY_WORKFOLDER_BAK=${MYBB_UTILITY_WORKFOLDER_BAK//\{MYBB_VERCODE\}/"${MYBB_INST_VERCODE}"}
	MYBB_UTILITY_WORKFOLDER_NEW=${MYBB_UTILITY_WORKFOLDER_NEW_BASE//\{MYBB_VERCODE\}/"${MYBB_TARGET_RELEASE_VERCODE}"}
	MYBB_UTILITY_RELEASE_DOWNLOADED=${MYBB_UTILITY_RELEASE_DOWNLOADED_BASE//\{MYBB_VERCODE\}/"${MYBB_TARGET_RELEASE_VERCODE}"}

	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_ROOT}" "working root"
	_cmd_preparedir "${MYBB_UTILITY_WORKFOLDER_BAK}" "backup folder"

	_cmd_getrls "${MYBB_TARGET_RELEASE_VERCODE}" 1

	do_print_msg 'debugmsg' "Taking backup of core files in current MyBB copy (${MYBB_INST_ROOT})..."

	_cmd_backup "${MYBB_INST_VERCODE}" "${MYBB_INST_ROOT}" "${MYBB_UTILITY_WORKFOLDER_BAK}"
	#_cmd_remove "${MYBB_INST_ROOT}" "${MYBB_UTILITY_WORKFOLDER_BAK}"
	_cmd_update "${MYBB_TARGET_RELEASE_VERCODE}" "${MYBB_UTILITY_WORKFOLDER_NEW}" "${MYBB_INST_ROOT}" 0

	do_print_msg 'info' "Update complete. Please check permissions for new created file(s)/folder(s)."
	do_print_msg 'info' "Backup files are saved in ${MYBB_UTILITY_WORKFOLDER_BAK}"
	do_print_msg 'info' "Now you need to perform the upgrade process from your browser:"
	do_print_msg 'info' "  1. Remove the installer lock file './install/lock', if it exists."
	do_print_msg 'info' "  2. Assume 'https://example.com/forum' is the forum URL, please open"
	do_print_msg 'info' "     'https://example.com/forum/install/' in your browser and then follow"
	do_print_msg 'info' "     the instruction listed on the upgrade page."
}



do_main "${@}"

do_exit


function _set_checksum_utility() {
	# Assign checksum utility for each MyBB version.
	if [ ${MYBB_VERCODE_NOW} -gt 1807 ]
	then
		MYBB_UPGRADER_CHECKSUM_UTIL_NOW="sha512sum"
	else
		MYBB_UPGRADER_CHECKSUM_UTIL_NOW="md5sum"
	fi
	MYBB_UPGRADER_CHECKSUM_UTIL_NOW=$(which "${MYBB_UPGRADER_CHECKSUM_UTIL_NOW}")

	if [ ${MYBB_VERCODE_NEW} -gt 1807 ]
	then
		MYBB_UPGRADER_CHECKSUM_UTIL_NEW="sha512sum"
	else
		MYBB_UPGRADER_CHECKSUM_UTIL_NEW="md5sum"
	fi
	MYBB_UPGRADER_CHECKSUM_UTIL_NEW=$(which "${MYBB_UPGRADER_CHECKSUM_UTIL_NEW}")
}

#set +o xtrace
