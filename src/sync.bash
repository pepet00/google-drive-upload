#!/usr/bin/env bash
# Sync a FOLDER to google drive forever using labbots/google-drive-upload
# shellcheck source=/dev/null

_usage() {
    printf "%b" "
The script can be used to sync your local folder to google drive.

Utilizes google-drive-upload bash scripts.\n
Usage: ${0##*/} [options.. ]\n
Options:\n
  -d | --directory - Gdrive foldername.\n
  -k | --kill - to kill the background job using pid number ( -p flags ) or used with input, can be used multiple times.\n
  -j | --jobs - See all background jobs that were started and still running.\n
     Use --jobs v/verbose to more information for jobs.\n
  -p | --pid - Specify a pid number, used for --jobs or --kill or --info flags, can be used multiple times.\n
  -i | --info - See information about a specific sync using pid_number ( use -p flag ) or use with input, can be used multiple times.\n
  -t | --time <time_in_seconds> - Amount of time to wait before try to sync again in background.\n
     To set wait time by default, use ${0##*/} -t default='3'. Replace 3 with any positive integer.\n
  -l | --logs - To show the logs after starting a job or show log of existing job. Can be used with pid number ( -p flag ).
     Note: If multiple pid numbers or inputs are used, then will only show log of first input as it goes on forever.
  -a | --arguments - Additional arguments for gupload commands. e.g: ${0##*/} -a '-q -o -p 4 -d'.\n
     To set some arguments by default, use ${0##*/} -a default='-q -o -p 4 -d'.\n
  -fg | --foreground - This will run the job in foreground and show the logs.\n
  -in | --include 'pattern' - Only include the files with the given pattern to upload.\n
       e.g: ${0##*/} local_folder --include "*1*", will only include with files with pattern '1' in the name.\n
  -ex | --exclude 'pattern' - Exclude the files with the given pattern from uploading.\n
       e.g: ${0##*/} local_folder --exclude "*1*", will exclude all files with pattern '1' in the name.\n
  -c | --command 'command name'- Incase if gupload command installed with any other name or to use in systemd service.\n
  --sync-detail-dir 'dirname' - Directory where a job information will be stored.
     Default: ${HOME}/.google-drive-upload\n
  -s | --service 'service name' - To generate systemd service file to setup background jobs on boot.\n
  -D | --debug - Display script command trace, use before all the flags to see maximum script trace.\n
  -h | --help - Display usage instructions.\n"
    exit 0
}

_short_help() {
    printf "No valid arguments provided, use -h/--help flag to see usage.\n"
    exit 0
}

###################################################
# Check if a pid exists by using ps
# Arguments: 1
#   ${1} = pid number of a sync job
# Result: return 0 or 1
###################################################
_check_pid() {
    { ps -p "${1}" 2>| /dev/null 1>&2 && return 0; } || return 1
}

###################################################
# Show information about a specific sync job
# Arguments: 1
#   ${1} = pid number of a sync job
#   ${2} = anything: Prints extra information ( optional )
#   ${3} = all information about a job ( optional )
# Result: show job info and set RETURN_STATUS
###################################################
_get_job_info() {
    declare input local_folder pid times extra
    pid="${1}" && input="${3:-$(grep "${pid}" "${SYNC_LIST}" || :)}"

    if [[ -n ${input} ]]; then
        if times="$(ps -p "${pid}" -o etimes --no-headers)"; then
            printf "\n%s\n" "PID: ${pid}"
            : "${input#*"|:_//_:|"}" && local_folder="${_%%"|:_//_:|"*}"

            printf "Local Folder: %s\n" "${local_folder}"
            printf "Drive Folder: %s\n" "${input##*"|:_//_:|"}"
            printf "Running Since: %s\n" "$(_display_time "${times}")"

            [[ -n ${2} ]] && {
                extra="$(ps -p "${pid}" -o %cpu,%mem --no-headers || :)"
                printf "CPU usage:%s\n" "${extra% *}"
                printf "Memory usage: %s\n" "${extra##* }"
                _setup_loop_variables "${local_folder}" "${input##*"|:_//_:|"}"
                printf "Success: %s\n" "$(_count < "${SUCCESS_LOG}")"
                printf "Failed: %s\n" "$(_count < "${ERROR_LOG}")"
            }
            RETURN_STATUS=0
        else
            RETURN_STATUS=1
        fi
    else
        RETURN_STATUS=11
    fi
    return 0
}

###################################################
# Remove a sync job information from database
# Arguments: 1
#   ${1} = pid number of a sync job
###################################################
_remove_job() {
    declare pid="${1}" input local_folder drive_folder new_list
    input="$(grep "${pid}" "${SYNC_LIST}" || :)"

    if [ -n "${pid}" ]; then
        : "${input##*"|:_//_:|"}" && local_folder="${_%%"|:_//_:|"*}"
        drive_folder="${input##*"|:_//_:|"}"
        new_list="$(grep -v "${pid}" "${SYNC_LIST}" || :)"
        printf "%s\n" "${new_list}" >| "${SYNC_LIST}"
    fi

    rm -rf "${SYNC_DETAIL_DIR:?}/${drive_folder_remove_job:-${2}}${local_folder_remove_job:-${3}}"
    # Cleanup dir if empty
    { [[ -z $(find "${SYNC_DETAIL_DIR:?}/${drive_folder_remove_job:-${2}}" -type f || :) ]] && rm -rf "${SYNC_DETAIL_DIR:?}/${drive_folder_remove_job:-${2}}"; } 2>| /dev/null 1>&2
    return 0
}

###################################################
# Kill a sync job and do _remove_job
# Arguments: 1
#   ${1} = pid number of a sync job
###################################################
_kill_job() {
    declare pid="${1}"
    kill -9 "${pid}" 2>| /dev/null 1>&2 || :
    _remove_job "${pid}"
    printf "Killed.\n"
}

###################################################
# Show total no of sync jobs running
# Arguments: 1
#   ${1} = v/verbose: Prints extra information ( optional )
###################################################
_show_jobs() {
    declare list pid total=0
    list="$(grep -v '^$' "${SYNC_LIST}" || :)"
    printf "%s\n" "${list}" >| "${SYNC_LIST}"

    while read -r -u 4 line; do
        if [[ -n ${line} ]]; then
            : "${line%%"|:_//_:|"*}" && pid="${_##*: }"
            _get_job_info "${pid}" "${1}" "${line}"
            { [[ ${RETURN_STATUS} = 1 ]] && _remove_job "${pid}"; } || { ((total += 1)) && no_task="printf"; }
        fi
    done 4< "${SYNC_LIST}"

    printf "\nTotal Jobs Running: %s\n" "${total}"
    [[ -z ${1} ]] && "${no_task:-:}" "For more info: %s -j/--jobs v/verbose\n" "${0##*/}"
    return 0
}

###################################################
# Setup required variables for a sync job
# Arguments: 1
#   ${1} = Local folder name which will be synced
###################################################
_setup_loop_variables() {
    declare folder="${1}" drive_folder="${2}"
    DIRECTORY="${SYNC_DETAIL_DIR}/${drive_folder}${folder}"
    PID_FILE="${DIRECTORY}/pid"
    SUCCESS_LOG="${DIRECTORY}/success_list"
    ERROR_LOG="${DIRECTORY}/failed_list"
    LOGS="${DIRECTORY}/logs"
}

###################################################
# Create folder and files for a sync job
###################################################
_setup_loop_files() {
    mkdir -p "${DIRECTORY}"
    for file in PID_FILE SUCCESS_LOG ERROR_LOG; do
        printf "" >> "${!file}"
    done
    PID="$(< "${PID_FILE}")"
}

###################################################
# Check for new files in the sync folder and upload it
# A list is generated everytime, success and error.
###################################################
_check_and_upload() {
    declare all initial new_files new_file

    mapfile -t initial < "${SUCCESS_LOG}"
    mapfile -t all <<< "$(printf "%s\n%s\n" "$(< "${SUCCESS_LOG}")" "$(< "${ERROR_LOG}")")"

    # check if folder is empty
    [[ $(printf "%b\n" ./*) = "./*" ]] && return 0

    all+=(*)
    # shellcheck disable=SC2086
    { [ -n "${INCLUDE_FILES}" ] && mapfile -t all <<< "$(printf "%s\n" "${all[@]}" | grep -E ${INCLUDE_FILES})"; } || :
    # shellcheck disable=SC2086
    mapfile -t new_files <<< "$(eval grep -vxEf <(printf "%s\n" "${initial[@]}") <(printf "%s\n" "${all[@]}") ${EXCLUDE_FILES} || :)"

    [[ -n ${new_files[*]} ]] && printf "" >| "${ERROR_LOG}" && {
        declare -A Aseen && for new_file in "${new_files[@]}"; do
            { [[ ${Aseen[new_file]} ]] && continue; } || Aseen[${new_file}]=x
            if eval "\"${COMMAND_PATH}\"" "\"${new_file}\"" "${ARGS}"; then
                printf "%s\n" "${new_file}" >> "${SUCCESS_LOG}"
            else
                printf "%s\n" "${new_file}" >> "${ERROR_LOG}"
                printf "%s\n" "Error: Input - ${new_file}"
            fi
            printf "\n"
        done
    }
    return 0
}

###################################################
# Loop _check_and_upload function, sleep for sometime in between
###################################################
_loop() {
    while :; do
        _check_and_upload
        sleep "${SYNC_TIME_TO_SLEEP}"
    done
}

###################################################
# Check if a loop exists with given input
# Result: return 0 - No existing loop, 1 - loop exists, 2 - loop only in database
#   if return 2 - then remove entry from database
###################################################
_check_existing_loop() {
    _setup_loop_variables "${FOLDER}" "${GDRIVE_FOLDER}"
    _setup_loop_files
    if [[ -z ${PID} ]]; then
        RETURN_STATUS=0
    elif _check_pid "${PID}"; then
        RETURN_STATUS=1
    else
        _remove_job "${PID}"
        _setup_loop_variables "${FOLDER}" "${GDRIVE_FOLDER}"
        _setup_loop_files
        RETURN_STATUS=2
    fi
    return 0
}

###################################################
# Start a new sync job by _loop function
# Print sync job information
# Result: Show logs at last and don't hangup if SHOW_LOGS is set
###################################################
_start_new_loop() {
    if [[ -n ${FOREGROUND} ]]; then
        printf "%b\n" "Local Folder: ${INPUT}\nDrive Folder: ${GDRIVE_FOLDER}\n"
        trap '_clear_line 1 && printf "\n" && _remove_job "" "${GDRIVE_FOLDER}" "${FOLDER}"; exit' INT TERM
        trap 'printf "Job stopped.\n" ; exit' EXIT
        _loop
    else
        (_loop &> "${LOGS}") & # A double fork doesn't get killed if script exits
        PID="${!}"
        printf "%s\n" "${PID}" >| "${PID_FILE}"
        printf "%b\n" "Job started.\nLocal Folder: ${INPUT}\nDrive Folder: ${GDRIVE_FOLDER}"
        printf "%s\n" "PID: ${PID}"
        printf "%b\n" "PID: ${PID}|:_//_:|${FOLDER}|:_//_:|${GDRIVE_FOLDER}" >> "${SYNC_LIST}"
        [[ -n ${SHOW_LOGS} ]] && tail -f "${LOGS}"
    fi
    return 0
}

###################################################
# Triggers in case either -j & -k or -l flag ( both -k|-j if with positive integer as argument )
# Priority: -j > -i > -l > -k
# Result: show either job info, individual info or kill job(s) according to set global variables.
#   Script exits after -j and -k if kill all is triggered )
###################################################
_do_job() {
    case "${JOB[*]}" in
        *SHOW_JOBS*)
            _show_jobs "${SHOW_JOBS_VERBOSE:-}"
            exit
            ;;
        *KILL_ALL*)
            PIDS="$(_show_jobs | grep -o 'PID:.*[0-9]' | sed "s/PID: //g" || :)" && total=0
            [[ -n ${PIDS} ]] && {
                for _pid in ${PIDS}; do
                    printf "PID: %s - " "${_pid##* }"
                    _kill_job "${_pid##* }"
                    ((total += 1))
                done
            }
            printf "\nTotal Jobs Killed: %s\n" "${total}"
            exit
            ;;
        *PIDS*)
            for pid in "${ALL_PIDS[@]}"; do
                [[ ${JOB_TYPE} =~ INFO ]] && {
                    _get_job_info "${pid}" more
                    [[ ${RETURN_STATUS} -gt 0 ]] && {
                        [[ ${RETURN_STATUS} = 1 ]] && _remove_job "${pid}"
                        printf "No job running with given PID ( %s ).\n" "${pid}" 1>&2
                    }
                }
                [[ ${JOB_TYPE} =~ SHOW_LOGS ]] && {
                    input="$(grep "${pid}" "${SYNC_LIST}" || :)"
                    if [[ -n ${input} ]]; then
                        _check_pid "${pid}" && {
                            : "${input#*"|:_//_:|"}" && local_folder="${_/"|:_//_:|"*/}"
                            _setup_loop_variables "${local_folder}" "${input/*"|:_//_:|"/}"
                            tail -f "${LOGS}"
                        }
                    else
                        printf "No job running with given PID ( %s ).\n" "${pid}" 1>&2
                    fi
                }
                [[ ${JOB_TYPE} =~ KILL ]] && {
                    _get_job_info "${pid}"
                    if [[ ${RETURN_STATUS} = 0 ]]; then
                        _kill_job "${pid}"
                    else
                        [[ ${RETURN_STATUS} = 1 ]] && _remove_job "${pid}"
                        printf "No job running with given PID ( %s ).\n" "${pid}" 1>&2
                    fi
                }
            done
            [[ ${JOB_TYPE} =~ (INFO|SHOW_LOGS|KILL) ]] && exit 0
            ;;
    esac
    return 0
}

###################################################
# Process all arguments given to the script
# Arguments: Many
#   ${@} = Flags with arguments
# Result: On
#   Success - Set all the variables
#   Error   - Print error message and exit
###################################################
_setup_arguments() {
    [[ $# = 0 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    unset SYNC_TIME_TO_SLEEP ARGS COMMAND_NAME DEBUG GDRIVE_FOLDER KILL SHOW_LOGS
    COMMAND_NAME="gupload"

    _check_longoptions() {
        [[ -z ${2} ]] &&
            printf '%s: %s: option requires an argument\nTry '"%s -h/--help"' for more information.\n' \
                "${0##*/}" "${1}" "${0##*/}" && exit 1
        return 0
    }

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h | --help) _usage ;;
            -D | --debug) DEBUG="true" && export DEBUG && _check_debug ;;
            -d | --directory)
                _check_longoptions "${1}" "${2}"
                GDRIVE_FOLDER="${2}" && shift
                ARGS+=" -C \"${GDRIVE_FOLDER}\" "
                ;;
            -j | --jobs)
                [[ ${2} = v* ]] && SHOW_JOBS_VERBOSE="true" && shift
                JOB=(SHOW_JOBS)
                ;;
            -p | --pid)
                _check_longoptions "${1}" "${2}"
                if [[ ${2} -gt 0 ]]; then
                    ALL_PIDS+=("${2}") && shift
                    JOB+=(PIDS)
                else
                    printf "-p/--pid only takes postive integer as arguments.\n"
                    exit 1
                fi
                ;;
            -i | --info) JOB_TYPE+="INFO" && INFO="true" ;;
            -k | --kill)
                JOB_TYPE+="KILL" && KILL="true"
                [[ ${2} = all ]] && JOB=(KILL_ALL) && shift
                ;;
            -l | --logs) JOB_TYPE+="SHOW_LOGS" && SHOW_LOGS="true" ;;
            -t | --time)
                _check_longoptions "${1}" "${2}"
                if [[ ${2} -gt 0 ]]; then
                    [[ ${2} = default* ]] && UPDATE_DEFAULT_TIME_TO_SLEEP="_update_config"
                    TO_SLEEP="${2/default=/}" && shift
                else
                    printf "-t/--time only takes positive integers as arguments, min = 1, max = infinity.\n"
                    exit 1
                fi
                ;;
            -a | --arguments)
                _check_longoptions "${1}" "${2}"
                [[ ${2} = default* ]] && UPDATE_DEFAULT_ARGS="_update_config"
                ARGS+="${2/default=/} " && shift
                ;;
            -fg | --foreground) FOREGROUND="true" && SHOW_LOGS="true" ;;
            -in | --include)
                _check_longoptions "${1}" "${2}"
                INCLUDE_FILES="${INCLUDE_FILES} -e '${2}' " && shift
                ;;
            -ex | --exclude)
                _check_longoptions "${1}" "${2}"
                EXCLUDE_FILES="${EXCLUDE_FILES} -e '${2}' " && shift
                ;;
            -c | --command)
                _check_longoptions "${1}" "${2}"
                CUSTOM_COMMAND_NAME="${2}" && shift
                ;;
            --sync-detail-dir)
                _check_longoptions "${1}" "${2}"
                SYNC_DETAIL_DIR="${2}" && shift
                ;;
            -s | --service)
                _check_longoptions "${1}" "${2}"
                SERVICE_NAME="${2}" && shift
                CREATE_SERVICE="true"
                ;;
            *)
                # Check if user meant it to be a flag
                if [[ ${1} = -* ]]; then
                    printf '%s: %s: Unknown option\nTry '"%s -h/--help"' for more information.\n' "${0##*/}" "${1}" "${0##*/}" && exit 1
                else
                    # If no "-" is detected in 1st arg, it adds to input
                    FINAL_INPUT_ARRAY+=("${1}")
                fi
                ;;
        esac
        shift
    done

    INFO_PATH="${HOME}/.google-drive-upload"
    CONFIG_INFO="${INFO_PATH}/google-drive-upload.configpath"
    [[ -f ${CONFIG_INFO} ]] && . "${CONFIG_INFO}"
    CONFIG="${CONFIG:-${HOME}/.googledrive.conf}"
    SYNC_DETAIL_DIR="${SYNC_DETAIL_DIR:-${INFO_PATH}/sync}"
    SYNC_LIST="${SYNC_DETAIL_DIR}/sync_list"
    mkdir -p "${SYNC_DETAIL_DIR}" && printf "" >> "${SYNC_LIST}"

    _do_job

    [[ -z ${FINAL_INPUT_ARRAY[*]} ]] && _short_help

    return 0
}

###################################################
# Grab config variables and modify defaults if necessary
# Result: grab COMMAND_NAME, INSTALL_PATH, and CONFIG
#   source CONFIG, update default values if required
###################################################
_config_variables() {
    COMMAND_NAME="${CUSTOM_COMMAND_NAME:-${COMMAND_NAME}}"
    VALUES_LIST="REPO COMMAND_NAME SYNC_COMMAND_NAME INSTALL_PATH TYPE TYPE_VALUE"
    VALUES_REGEX="" && for i in ${VALUES_LIST}; do
        VALUES_REGEX="${VALUES_REGEX:+${VALUES_REGEX}|}^${i}=\".*\".* # added values"
    done

    # Check if command exist, not necessary but just in case.
    {
        COMMAND_PATH="$(command -v "${COMMAND_NAME}")" 1> /dev/null &&
            SCRIPT_VALUES="$(grep -E "${VALUES_REGEX}|^SELF_SOURCE=\".*\"" "${COMMAND_PATH}" || :)" && eval "${SCRIPT_VALUES}" &&
            [[ -n "${REPO:+${COMMAND_NAME:+${INSTALL_PATH:+${TYPE:+${TYPE_VALUE}}}}}" ]] && :
    } || { printf "Error: %s is not installed, use -c/--command to specify.\n" "${COMMAND_NAME}" 1>&2 && exit 1; }

    ARGS+=" -q "
    SYNC_TIME_TO_SLEEP="3"
    # Config file is created automatically after first run
    # shellcheck source=/dev/null
    [[ -r ${CONFIG} ]] && . "${CONFIG}"

    SYNC_TIME_TO_SLEEP="${TO_SLEEP:-${SYNC_TIME_TO_SLEEP}}"
    ARGS+=" ${SYNC_DEFAULT_ARGS:-} "
    "${UPDATE_DEFAULT_ARGS:-:}" SYNC_DEFAULT_ARGS " ${ARGS} " "${CONFIG}"
    "${UPDATE_DEFAULT_TIME_TO_SLEEP:-:}" SYNC_TIME_TO_SLEEP "${SYNC_TIME_TO_SLEEP}" "${CONFIG}"
    return 0
}

###################################################
# Print systemd service file contents
###################################################
_systemd_service_contents() {
    declare username="${LOGNAME:?Give username}" install_path="${INSTALL_PATH:?Missing install path}" \
        cmd="${COMMAND_NAME:?Missing command name}" sync_cmd="${SYNC_COMMAND_NAME:?Missing gsync cmd name}" \
        all_argumnets="${ALL_ARGUMNETS:-}"

    printf "%s\n" '# Systemd service file - start
[Unit]
Description=google-drive-upload synchronisation service
After=network.target

[Service]
Type=simple
User='"${username}"'
Restart=on-abort
RestartSec=3
ExecStart="'"${install_path}/${sync_cmd}"'" --foreground --command "'"${install_path}/${cmd}"'" --sync-detail-dir "/tmp/sync" '"${all_argumnets}"'

# Security
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
# Systemd service file - end'
}

###################################################
# Create systemd service wrapper script for managing the service
# Arguments: 3
#   ${1} = Service name
#   ${1} = Service file contents
#   ${1} = Script name
# Result: print the script contents to script file
###################################################
_systemd_service_script() {
    declare name="${1:?Missing service name}" script_name script \
        service_file_contents="${2:?Missing service file contents}"
    script_name="${3:?Missing script name}"

    # shellcheck disable=SC2016
    script='#!/usr/bin/env bash
set -e

_usage() {
    printf "%b" "# Service name: '"'${name}'"'

# Print the systemd service file contents
bash \"${0##*/}\" print\n
# Add service to systemd files ( this must be run before doing any of the below )
bash \"${0##*/}\" add\n
# Start or Stop the service
bash \"${0##*/}\" start / stop\n
# Enable or Disable as a boot service:
bash \"${0##*/}\" enable / disable\n
# See logs
bash \"${0##*/}\" logs\n
# Remove the service from system
bash \"${0##*/}\" remove\n\n"

    _status
    exit 0
}

_status() {
    declare status current_status
    status="$(systemctl status '"'${name}'"' 2>&1 || :)"
    current_status="$(printf "%s\n" "${status}" | env grep -E "●.*|(Loaded|Active|Main PID|Tasks|Memory|CPU): .*" || :)"

    printf "%s\n" "Current status of service: ${current_status:-${status}}"
    return 0
}

unset TMPFILE

[[ $# = 0 ]] && _usage

CONTENTS='"'${service_file_contents}'"'

_add_service() {
    declare service_file_path="/etc/systemd/system/'"${name}"'.service"
    printf "%s\n" "Service file path: ${service_file_path}"
    if [[ -f ${service_file_path} ]]; then
        printf "%s\n" "Service file already exists. Overwriting"
        sudo mv "${service_file_path}" "${service_file_path}.bak" || exit 1
        printf "%s\n" "Existing service file was backed up."
        printf "%s\n" "Old service file: ${service_file_path}.bak"
    else
        [[ -z ${TMPFILE} ]] && {
            { { command -v mktemp 1>|/dev/null && TMPFILE="$(mktemp -u)"; } ||
                TMPFILE="${PWD}/.$(_t="$(printf "%(%s)T\\n" "-1")" && printf "%s\n" "$((_t * _t))").LOG"; } || exit 1
        }
        export TMPFILE
        trap "exit" INT TERM
        _rm_tmpfile() { rm -f "${TMPFILE:?}" ; }
        trap "_rm_tmpfile" EXIT
        trap "" TSTP # ignore ctrl + z

        { printf "%s\n" "${CONTENTS}" >|"${TMPFILE}" && sudo cp "${TMPFILE}" /etc/systemd/system/'"${name}"'.service; } ||
            { printf "%s\n" "Error: Failed to add service file to system." && exit 1 ;}
    fi
    sudo systemctl daemon-reload || printf "%s\n" "Could not reload the systemd daemon."
    printf "%s\n" "Service file was successfully added."
    return 0
}

_service() {
    declare service_name='"'${name}'"' action="${1:?}" service_file_path
    service_file_path="/etc/systemd/system/${service_name}.service"
    printf "%s\n" "Service file path: ${service_file_path}"
    [[ -f ${service_file_path} ]] || { printf "%s\n" "Service file does not exist." && exit 1; }
    sudo systemctl daemon-reload || exit 1
    case "${action}" in
        log*) sudo journalctl -u "${service_name}" -f ;;
        rm | remove)
            sudo systemctl stop "${service_name}" || :
            if  sudo rm -f /etc/systemd/system/"${service_name}".service; then
                sudo systemctl daemon-reload || :
                printf "%s\n" "Service removed." && return 0
            else
                printf "%s\n" "Error: Cannot remove." && exit 1
            fi
            ;;
        *)
            declare success="${2:?}" error="${3:-}"
            if sudo systemctl "${action}" "${service_name}"; then
                printf "%s\n" "Success: ${service_name} ${success}." && return 0
            else
                printf "%s\n" "Error: Cannot ${action} ${service_name} ${error}." && exit 1
            fi
            ;;
    esac
    return 0
}

while [[ "${#}" -gt 0 ]]; do
    case "${1}" in
        print) printf "%s\n" "${CONTENTS}" ;;
        add) _add_service ;;
        start) _service start started ;;
        stop) _service stop stopped ;;
        enable) _service enable "boot service enabled" "boot service" ;;
        disable) _service disable "boot service disabled" "boot service" ;;
        logs) _service logs ;;
        remove) _service rm ;;
        *) printf "%s\n" "Error: No valid options provided." && _usage ;;
    esac
    shift
done'
    printf "%s\n" "${script}" >| "${script_name}"
    return 0
}

###################################################
# Process all the values in "${FINAL_INPUT_ARRAY[@]}"
# Result: Start the sync jobs for given folders, if running already, don't start new.
#   If a pid is detected but not running, remove that job.
#   If service script is going to be created then don,t touch the jobs
###################################################
_process_arguments() {
    declare current_folder && declare -A Aseen
    for INPUT in "${FINAL_INPUT_ARRAY[@]}"; do
        { [[ ${Aseen[${INPUT}]} ]] && continue; } || Aseen[${INPUT}]=x
        ! [[ -d ${INPUT} ]] && printf "\nError: Invalid Input ( %s ), no such directory.\n" "${INPUT}" && continue
        current_folder="$(pwd)"
        FOLDER="$(cd "${INPUT}" && pwd)" || exit 1
        [[ -n ${DEFAULT_ACCOUNT} ]] && _set_value indirect ROOT_FOLDER_NAME "ACCOUNT_${DEFAULT_ACCOUNT}_ROOT_FOLDER_NAME"
        GDRIVE_FOLDER="${GDRIVE_FOLDER:-${ROOT_FOLDER_NAME:-Unknown}}"

        [[ -n ${CREATE_SERVICE} ]] && {
            ALL_ARGUMNETS="\"${FOLDER}\" ${TO_SLEEP:+-t \"${TO_SLEEP}\"} -a \"${ARGS//  / }\""
            num="${num+$((num += 1))}"
            service_name="gsync-${SERVICE_NAME}${num:+_${num}}"
            script_name="${service_name}.service.sh"
            _systemd_service_script "${service_name}" "$(_systemd_service_contents)" "${script_name}"

            _print_center "normal" "=" "="
            bash "${script_name}"
            _print_center "normal" "=" "="
            continue
        }

        cd "${FOLDER}" || exit 1
        _check_existing_loop
        case "${RETURN_STATUS}" in
            0 | 2) _start_new_loop ;;
            1)
                printf "%b\n" "Job is already running.."
                if [[ -n ${INFO} ]]; then
                    _get_job_info "${PID}" more "PID: ${PID}|:_//_:|${FOLDER}|:_//_:|${GDRIVE_FOLDER}"
                else
                    printf "%b\n" "Local Folder: ${INPUT}\nDrive Folder: ${GDRIVE_FOLDER}"
                    printf "%s\n" "PID: ${PID}"
                fi

                [[ -n ${KILL} ]] && _kill_job "${PID}" && exit
                [[ -n ${SHOW_LOGS} ]] && tail -f "${LOGS}"
                ;;
        esac
        cd "${current_folder}" || exit 1
    done
    return 0
}

main() {
    [[ $# = 0 ]] && _short_help

    set -o noclobber -o pipefail

    [[ -z ${SELF_SOURCE} ]] && {
        UTILS_FOLDER="${UTILS_FOLDER:-${PWD}}"
        { . "${UTILS_FOLDER}"/bash/common-utils.bash && . "${UTILS_FOLDER}"/common/common-utils.sh; } || { printf "Error: Unable to source util files.\n" && exit 1; }
    }

    trap '' TSTP # ignore ctrl + z

    _setup_arguments "${@}"
    _check_debug
    _config_variables
    _process_arguments
}

main "${@}"
