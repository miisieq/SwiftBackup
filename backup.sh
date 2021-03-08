#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CONFIGURATION_FILE_PATH="${DIR}/.env"

if [[ ! -f "${CONFIGURATION_FILE_PATH}" ]]; then
    echo "Configuration file \"${CONFIGURATION_FILE_PATH}\" does not exist."
    exit 1
fi

CONFIGURATION_FILE_PERMISSIONS=$(stat -c "%a" "${CONFIGURATION_FILE_PATH}")
if [[ ! 600 == "${CONFIGURATION_FILE_PERMISSIONS}" ]]; then
    echo "Permissions 0${CONFIGURATION_FILE_PERMISSIONS} for \"${CONFIGURATION_FILE_PATH}\" are too open."
    echo "It is recommended that your configuration files are NOT accessible by others."
    echo "You can execute \"chmod 600 ${CONFIGURATION_FILE_PATH}\" to set proper permissions."
    exit 1
fi

source "${CONFIGURATION_FILE_PATH}"

function check_variables_existence() {
    for REQUIRED_VARIABLE in "$@"; do
        if [[ -z "${!REQUIRED_VARIABLE}" ]]; then
            echo "Required variable \"${REQUIRED_VARIABLE}\" is empty or not set."
            exit 1
        fi
    done
}

function check_commands_existence() {
    for REQUIRED_COMMAND in "$@"; do
        if [[ ! -x "$(command -v ${REQUIRED_COMMAND})" ]]; then
            echo "Required command \"${REQUIRED_COMMAND}\" does not exist."
            exit 1
        fi
    done
}

function upload_file() {
    AUTHORIZATION="
        --auth-version 3
        --os-auth-url ${BACKUP_OS_AUTH_URL}
        --os-username ${BACKUP_OS_USERNAME}
        --os-password ${BACKUP_OS_PASSWORD}
        --os-tenant-name ${BACKUP_OS_TENANT_NAME}
        --os-tenant-id ${BACKUP_OS_TENANT_ID}
        --os-region-name ${BACKUP_OS_REGION_NAME}
    "
    swift ${AUTHORIZATION} upload --quiet --header "X-Delete-After: $BACKUP_OS_TTL" "${BACKUP_OS_CONTAINER}" "${1}"
    UPLOADED_SIZE=$(swift list ${AUTHORIZATION} "${BACKUP_OS_CONTAINER}" --lh -p "$1" | head -n 1 | awk '{print $1}')
    printf " – %s: %s\n" "${1}" "${UPLOADED_SIZE}"
}

check_variables_existence \
    "BACKUP_OS_AUTH_URL" \
    "BACKUP_OS_USERNAME" \
    "BACKUP_OS_PASSWORD" \
    "BACKUP_OS_TENANT_NAME" \
    "BACKUP_OS_TENANT_ID" \
    "BACKUP_OS_REGION_NAME" \
    "BACKUP_OS_CONTAINER" \
    "BACKUP_OS_TTL"

check_commands_existence "rm" "swift"

FILES_TO_UPLOAD=()

# Check required environmental variables and commands for MySQL backup.
if [[ ! -z "${BACKUP_MYSQL_DATABASES}" ]]; then
    check_variables_existence "BACKUP_MYSQL_HOST" "BACKUP_MYSQL_USER" "BACKUP_MYSQL_PASSWORD" "BACKUP_MYSQL_PORT"
    check_commands_existence "mysqldump" "gzip"
fi

# Dump and compress MySQL databases.
for MYSQL_DATABASE in "${BACKUP_MYSQL_DATABASES[@]}"; do
    FILENAME="db_${MYSQL_DATABASE}_$(date '+%Y-%m-%d_%H-%M-%S').sql.gz"
    mysqldump \
        --ssl-mode=DISABLED \
        --column-statistics=0 \
        --host="$BACKUP_MYSQL_HOST" \
        --user="$BACKUP_MYSQL_USER" \
        --password="$BACKUP_MYSQL_PASSWORD" \
        --port="$BACKUP_MYSQL_PORT" \
        "$MYSQL_DATABASE" | gzip > "$FILENAME"
    FILES_TO_UPLOAD+=("${FILENAME}")
done

# Check required commands for files backup.
if [[ ! -z "${BACKUP_DIRECTORIES}" ]]; then
    check_commands_existence "tar"
fi

# Dump and compress directories.
for BACKUP_DIRECTORY in "${BACKUP_DIRECTORIES[@]}"; do
    if [[ ! -d "${BACKUP_DIRECTORY}" ]]; then
        echo "Directory \"${BACKUP_DIRECTORY}\" does not exist."
        exit 1
    fi

    FILENAME="$(echo "${BACKUP_DIRECTORY}" | sed -r 's/[\/]+/_/g')_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
    tar --xform s:'./':: --create --gzip --file="${FILENAME}" --directory="${BACKUP_DIRECTORY}/" .
    FILES_TO_UPLOAD+=("${FILENAME}")
done

if [[ -n "${FILES_TO_UPLOAD}" ]]; then
    echo "Files uploaded to OpenStack Swift container – \"${BACKUP_OS_CONTAINER}\":"
fi

# Upload files to OpenStack Swift.
for FILE_TO_UPLOAD in "${FILES_TO_UPLOAD[@]}"; do
    upload_file "${FILE_TO_UPLOAD}"
    rm "${FILE_TO_UPLOAD}"
done
