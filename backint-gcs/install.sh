#!/usr/bin/env bash

set -eu -o pipefail

readonly INSTALL_DESTINATION="/usr/sap/$SAPSYSTEMNAME/SYS/global/hdb/opt/backint/backint-gcs"
readonly GCS_BUCKET="https://www.googleapis.com/download/storage/v1/b/sapdeploy/o/backint-gcs"
readonly LATEST="$GCS_BUCKET%2FLATEST.txt"
readonly PACKAGE_BASE="$GCS_BUCKET%2Fsap-backint-gcs"
readonly USER_AGENT="sap-backint-gcs-installer/1.0 (GPN: SAP Backint for GCS)"
readonly LOGS_DIR="$INSTALL_DESTINATION/logs"
readonly LOGGING_PROPERTIES="$INSTALL_DESTINATION/logging.properties"
readonly PARAMETERS_FILE="$INSTALL_DESTINATION/parameters.txt"
readonly UPDATE_LOCK="$INSTALL_DESTINATION/.updating.lock"

download () {
    # Downloads and unzips the archive from GCS
    # $1 - latest version number
    local version="$1"
    local package="${PACKAGE_BASE}-${version}.tar.gz"
    local archive="sap-backint-gcs.tar.gz"
    curl --show-error --silent --fail --user-agent "$USER_AGENT" \
        --output "$INSTALL_DESTINATION/$archive" "${package}?alt=media"
    tar -xz --directory "$INSTALL_DESTINATION" -f "$INSTALL_DESTINATION/$archive"
    echo "$version" | tee "$INSTALL_DESTINATION/VERSION.txt" > /dev/null
    rm "$INSTALL_DESTINATION/$archive"
}

create_logging_properties() {
    # Creates the logging properties file
    cat > "$LOGGING_PROPERTIES" <<EOF
.level = INFO
com.google.cloud.partners.handlers = java.util.logging.FileHandler
java.util.logging.SimpleFormatter.format=%1\$tY-%1\$tm-%1\$tdT%1\$tH:%1\$tM:%1\$tS.%1\$tL%1\$tZ %4\$s - %5\$s%6\$s%n
java.util.logging.FileHandler.pattern = ${LOGS_DIR}/backint-gcs-%u.log
java.util.logging.FileHandler.append = true
java.util.logging.FileHandler.count = 100
java.util.logging.FileHandler.limit = 10485760
java.util.logging.FileHandler.formatter = java.util.logging.SimpleFormatter
EOF
    chmod 0644 "$LOGGING_PROPERTIES"
}

create_parameters_file() {
    # Creates the custom backint parameters file
    cat > "$PARAMETERS_FILE" <<EOF
#BUCKET <GCS Bucket Name>
EOF
      chmod 0644 "$PARAMETERS_FILE"
      echo "Please update \"$PARAMETERS_FILE\" with your GCS bucket name." \
          "If you are not using Application Default Credentials, you must save your GCP Service" \
          "Account credentials to file and add a line containing #SERVICE_ACCOUNT"\
          "<path_to_creds> to \"$PARAMETERS_FILE\""
}

create_backint() {
    # Creates the backint executable script based on the current version
    # $1 - latest version number
    local jar="$(ls $INSTALL_DESTINATION/*$version.jar)"
    cat > "$INSTALL_DESTINATION/backint" <<EOF
#!/usr/bin/env bash

readonly SCRIPT="\$0"
readonly ARGUMENTS="\$@"

check_and_update() {
    # Checks for and installs a newer version if one exists.
    local installed="\$(cat ${INSTALL_DESTINATION}/VERSION.txt)"
    local latest="\$(curl --show-error --silent --fail --user-agent "$USER_AGENT" \\
        --output - "${LATEST}?alt=media")"
    local updated=1
    if [[ "\$latest" > "\$installed" ]]
    then
        echo "\$(date +'%Y-%m-%d %H:%M:%S %Z') - Updating \$installed to \$latest" \\
            >> "${LOGS_DIR}/installation.log"
        touch "$UPDATE_LOCK"
        curl --show-error --silent --fail --user-agent "$USER_AGENT" \\
            "${GCS_BUCKET}%2Finstall.sh?alt=media" | bash
        updated=\$?
        rm "$UPDATE_LOCK"
    fi
    return \$updated
}

wait_for_update() {
    # If an update is in progress, wait for up to 10 seconds
    local checks=10
    while (( checks > 0 ))
    do
        [[ ! -a "$UPDATE_LOCK" ]] && return 0
        echo "\$(date +'%Y-%m-%d %H:%M:%S %Z') - Update in progress, wait for \${checks}s" >> \\
            "${LOGS_DIR}/installation.log"
        sleep 1
        (( checks -= 1 ))
    done
    echo "\$(date +'%Y-%m-%d %H:%M:%S %Z') - Update did not complete after 10s" >> \\
        "${LOGS_DIR}/installation.log"
    return 1
}

main() {
    # Main execution sequence
    local updated=1
    if [[ -a "$UPDATE_LOCK" ]]
    then
        wait_for_update
        updated=\$?
    else
        check_and_update
        updated=\$?
    fi

    if [[ \$updated == 0 ]]
    then
        # Relaunch with the same parameters
        "\$SCRIPT" "\$ARGUMENTS"
        exit \$?
    fi

    # Invoke the backint JAR
    ${INSTALL_DESTINATION}/jre/bin/java \\
        -Djava.util.logging.config.file=${INSTALL_DESTINATION}/logging.properties \\
        -jar ${jar} \$ARGUMENTS
}

main
EOF
    chmod 0755 "$INSTALL_DESTINATION/backint"
}

install() {
    # Creates the backint logging properties file, parameters file, executable script and symlinks
    # $1 - latest version number
    local version="$1"

    # Create logging properties file (if non-existent)
    if [[ ! -a "$LOGGING_PROPERTIES" ]]
    then
        create_logging_properties
    fi

    # Create parameter file (if non-existent)
    if [[ ! -a "$PARAMETERS_FILE" ]]
    then
        create_parameters_file
    fi

    # Create the backint executable
    create_backint "$version"

    # Make symlinks
    ln -sf "$INSTALL_DESTINATION/backint" "/usr/sap/$SAPSYSTEMNAME/SYS/global/hdb/opt/hdbbackint"
    if [[ ! -d "/usr/sap/$SAPSYSTEMNAME/SYS/global/hdb/opt/hdbconfig/" ]]
    then
        mkdir "/usr/sap/$SAPSYSTEMNAME/SYS/global/hdb/opt/hdbconfig/"
    fi
    ln -sf "$PARAMETERS_FILE" "/usr/sap/$SAPSYSTEMNAME/SYS/global/hdb/opt/hdbconfig/"

    echo "$(date +'%Y-%m-%d %H:%M:%S %Z') - Installed version $version" \
        >> "$LOGS_DIR/installation.log"
}

main() {
    local latest="$(curl --show-error --silent --fail --user-agent "$USER_AGENT" \
        --output - "${LATEST}?alt=media")"
    [[ -d "$INSTALL_DESTINATION" ]] || mkdir -p -m 0755 "$LOGS_DIR"
    download $latest
    install $latest
}

main
