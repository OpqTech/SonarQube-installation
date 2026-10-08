#!/bin/bash

SONAR_VERSION="26.9.0.129388"
SONAR_USER="ubuntu"
SONAR_HOME="/opt/sonarqube/sonarqube-${SONAR_VERSION}"
SONAR_SH="${SONAR_HOME}/bin/linux-x86-64/sonar.sh"
DB_NAME="sonarqube"
DB_USER="sonar"

# Stops the script with a message when a step fails
fail() {
	echo "            -> FAILED: $1"
	exit 1
}

# Runs one SQL statement as the PostgreSQL admin user
run_psql() {
	(cd /tmp && sudo -u postgres psql -v ON_ERROR_STOP=1 -qtAc "$1")
}

# Starts PostgreSQL and waits until it accepts connections
start_postgres() {
	# The package skips creating its cluster when the SSH session carries an invalid locale (common from macOS)
	if [ -z "$(pg_lsclusters -h 2>/dev/null)" ]; then
		PG_VERSION=$(ls /usr/lib/postgresql 2>/dev/null | sort -n | tail -1)
		[ -n "$PG_VERSION" ] || return 1
		sudo pg_createcluster --locale C.UTF-8 "$PG_VERSION" main > /dev/null || return 1
	fi
	sudo systemctl enable --now postgresql > /dev/null 2>&1
	for i in $(seq 1 30); do
		run_psql "SELECT 1" > /dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}

printf "\n################################################################\n"
echo "#                                                              #"
echo "#                     ***OpqTech***                            #"
echo "#                  Sonarqube  Installation                     #"
echo "#                                                              #"
echo "################################################################"

# SonarQube (web + compute engine + elasticsearch) does not start on small instances
TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$TOTAL_MEM_MB" -lt 3500 ]; then
	printf "\n*****WARNING: only %s MB RAM found. SonarQube needs 4 GB (t3.large or bigger)\n" "$TOTAL_MEM_MB"
fi

# Installing necessary packages
printf "\n\n*****Installing necessary packages\n"
sudo apt-get update -y > /dev/null || fail "apt-get update"
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 LC_ALL=C.UTF-8 apt-get install -y openjdk-25-jre-headless unzip curl openssl postgresql > /dev/null || fail "package installation"
java -version > /dev/null 2>&1 || fail "java is not available after installation"
echo "            -> Done"

# Kernel settings required by the Elasticsearch bundled with SonarQube
echo "*****Applying kernel settings for Elasticsearch"
printf "vm.max_map_count=524288\nfs.file-max=131072\n" | sudo tee /etc/sysctl.d/99-sonarqube.conf > /dev/null
sudo sysctl --system > /dev/null || fail "sysctl"
echo "            -> Done"

# Creating PostgreSQL database (an existing database is kept, only the password is renewed)
echo "*****Creating PostgreSQL database for SonarQube"
start_postgres || fail "PostgreSQL did not start"
DB_PASSWORD=$(openssl rand -hex 16)
[ -n "$DB_PASSWORD" ] || fail "password generation"
run_psql "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || run_psql "CREATE ROLE ${DB_USER} LOGIN" || fail "create database user"
run_psql "ALTER ROLE ${DB_USER} PASSWORD '${DB_PASSWORD}'" || fail "set database password"
run_psql "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || run_psql "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0" || fail "create database"
echo "            -> Done"

# Downloading SonarQube to OPT folder
echo "*****Downloading SonarQube ${SONAR_VERSION} version"
cd /opt || fail "cd /opt"
# Stop a previous installation, otherwise it keeps holding port 9000
[ -f "$SONAR_SH" ] && sudo -H -u "$SONAR_USER" bash "$SONAR_SH" stop > /dev/null 2>&1
sudo rm -rf sonarqube*
sudo wget -q "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONAR_VERSION}.zip" || fail "download"
sudo unzip -q "sonarqube-${SONAR_VERSION}.zip" -d /opt/sonarqube || fail "unzip"
sudo rm -rf "sonarqube-${SONAR_VERSION}.zip"
echo "            -> Done"

# Changing Ownership as Sonarqube Does not work with Root User
echo "*****Changing Ownership of file to ${SONAR_USER} User"
sudo chown -R "${SONAR_USER}:" /opt/sonarqube || fail "chown"
# The zip does not always keep the execute bit on the launcher scripts
sudo chmod +x "$SONAR_SH" "${SONAR_HOME}"/elasticsearch/bin/* || fail "chmod"
echo "            -> Done"

# Pointing SonarQube to PostgreSQL instead of the embedded H2 database
echo "*****Configuring SonarQube to use PostgreSQL"
printf "\nsonar.jdbc.username=%s\nsonar.jdbc.password=%s\nsonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/%s\n" "$DB_USER" "$DB_PASSWORD" "$DB_NAME" | sudo tee -a "${SONAR_HOME}/conf/sonar.properties" > /dev/null || fail "sonar.properties"
sudo chmod 600 "${SONAR_HOME}/conf/sonar.properties"
echo "            -> Done"

# Starting SonarQube Service
echo "*****Starting SonarQube Server"
sudo -H -u "$SONAR_USER" bash -c "ulimit -n 131072 2>/dev/null; ulimit -u 8192 2>/dev/null; bash '$SONAR_SH' start" > /dev/null || fail "sonar.sh start"

# sonar.sh returns immediately, so wait until the server really answers
echo "*****Waiting for SonarQube to come up (can take 2-3 minutes)"
SONAR_STATUS=""
for i in $(seq 1 60); do
	SONAR_STATUS=$(curl -s --max-time 5 http://localhost:9000/api/system/status | grep -o '"status":"[A-Z_]*"' | cut -d'"' -f4)
	[ "$SONAR_STATUS" = "UP" ] && break
	# Give up early if the process has died
	sudo -H -u "$SONAR_USER" bash "$SONAR_SH" status > /dev/null 2>&1 || break
	sleep 5
done

# Check if SonarQube is working
printf "\n################################################################ \n\n"
if [ "$SONAR_STATUS" = "UP" ]; then
	echo "SonarQube installed Successfully"
	echo "Access SonarQube using http://$(curl -s ifconfig.me):9000  (admin / admin)"
else
	echo "SonarQube installation failed (status: ${SONAR_STATUS:-not running})"
	echo "Last lines of the logs:"
	sudo tail -n 20 "${SONAR_HOME}"/logs/sonar.log "${SONAR_HOME}"/logs/es.log 2>/dev/null
fi
printf "\n################################################################ \n\n"
