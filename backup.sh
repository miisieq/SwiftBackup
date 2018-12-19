#!/usr/bin/env bash

source ./.env

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
        --auth-version 2
        --os-auth-url ${BACKUP_OS_AUTH_URL}
        --os-username ${BACKUP_OS_USERNAME}
        --os-password ${BACKUP_OS_PASSWORD}
        --os-tenant-name ${BACKUP_OS_TENANT_NAME}
        --os-tenant-id ${BACKUP_OS_TENANT_ID}
        --os-region-name ${BACKUP_OS_REGION_NAME}
    "
    swift ${AUTHORIZATION} upload --quiet --header "X-Delete-After: $BACKUP_OS_TTL" "${BACKUP_OS_CONTAINER}" "${1}"
    UPLOADED_SIZE=$(swift list ${AUTHORIZATION} "${BACKUP_OS_CONTAINER}" --lh -p "$1" | head -n 1 | awk '{print $1}')
    printf "%s: %s\n" "${1}" "${UPLOADED_SIZE}"
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
        --host="$BACKUP_MYSQL_HOST" \
        --user="$BACKUP_MYSQL_USER" \
        --password="$BACKUP_MYSQL_PASSWORD" \
        --port="$BACKUP_MYSQL_PORT" \
        "$MYSQL_DATABASE" | gzip > "$FILENAME"
    FILES_TO_UPLOAD+=("${FILENAME}")
done

# Wysyłka plików do OpenStack Swift.
for FILE_TO_UPLOAD in "${FILES_TO_UPLOAD[@]}"; do
    upload_file "${FILE_TO_UPLOAD}"
    rm "${FILE_TO_UPLOAD}"
done
