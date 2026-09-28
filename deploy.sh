set -e 

# main 
APP_NAME="taskboard"
APP_DIR="${HOME}/${APP_NAME}"
REPOSITORY_URL="https://github.com/sharton/taskboard.git"
DB_NAME="taskboard"
DB_USER="taskboard"
DB_PASSWORD="taskboard"
APP_PASSWORD="taskboard"
APP_PORT="8000"
APP_HOST="0.0.0.0"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/api/health"

# function

log() {
	echo "[INFO] $1"
}

error() {
	echo "[ERROR] $1" >&2
	exit 1
}

check() {
	if [ $? -ne 0 ]; then 
		error "$1"
	fi
}

#1 Installing important programs

log "Proverka and ustanovka sistem zavivsimostey"

if command -v apt-get >/dev/null 2>&1; then
	PKG_MANAGER="apt-get"
	UPDATE_CMD="sudo apt-get update -qq"
	INSTALL_CMD="sudo apt-get install -y -qq"
elif command -v dnf >/dev/null 2>&1; then
	PKG_MANAGER="dnf"
	UPDATE_CMD="sudo dnf check-update || true"
	INSTALL_CMD="sudo dnf install -y"
elif command -v yum >/dev/null 2>&1; then
	PKG_MANAGER="yum"
	UPDATE_CMD="sudo yum check-update || true"
	INSTALL_CMD="sudo yum install -y"
else 
	error "Nuzhen apt, dnf, yum."
fi

NEED_UPDATE=0

if ! command -v git >/dev/null 2>&1; then 
	log "git ne naiden - budet ustanovlen"
	NEED_UPDATE=1
fi

if ! command -v python3 >/dev/null 2>&1; then 
	log "python3 ne naiden - budet ustanovlen"
	NEED_UPDATE=1
fi

if ! command -v pip3 >/dev/null 2>&1 && ! python3 -m pip --version >/dev/null 2>&1; then
	log "pip ne naiden - budet ustanovlen"
	NEED_UPDATE=1
fi

if ! command -v psql >/dev/null 2>&1; then
	log "PostgreSQL ne naiden - budet ustanovlen"
	NEED_UPDATE=1
fi

if [ "$NEED_UPDATE" -eq 1 ]; then
	log "Update list of package..."
	$UPDATE_CMD
	check "NE udalos update the list of package"

	log "Install nedostaushih paketov"
	if [ "$PKG_MANAGER" = "apt-get" ]; then 
		$INSTALL_CMD git python3 python3-venv python3-pip postgresql postgresql-contrib
	else
		$INSTALL_CMD git python3 python3-pip postgresql postgresql-server 
	fi

	check "Ne udalos install the list of package"
else
	log "Vse neobhodimye programm uzhe ustanovleny"
fi

	if [ "$PKG_MANAGER" = "apt-get" ]; then 
		if ! python3 -c "import venv" >/dev/null 2>&1; then
			log "Installing python3-venv..."
			$INSTALL_CMD python3-venv
			check "Ne udalos Install python3-venv"
		fi
	fi 

#2 Poluchenie ishodnogo code

log "Poluchenie ishodnogo coda app..."

if [ -d "${APP_DIR}/.git" ]; then
	log "Repozitoriy uzhe sushestvuet v ${APP_DIR} - propuskaem clonirovanie"
else 
	if [ -d "${APP_DIR}" ]; then
		error "Directoria ${APP_DIR} sushestvuet, no ne yavlaetca git-repozitoriem"
	fi
	log "Clonirovanie ${REPOZITORY_URL} -> ${APP_DIR}"
	git clone "${REPOZITORY_URL}" "${APP_DIR}"
	check "Ne udalos clonirovat repozitoriy"
fi 

cd "${APP_DIR}" || error "Ne udalos pereyty v ${APP_DIR}"

#3 Sozdanie virtualnogo ocruzhenia

log "Nastroyka virtualnogo ocruzhenia Python..."

if [ -d ".venv" ]; then
	log "Virtualnoe ocruzhenie .venv uzhe sushestvuet - ispolzovat ego"
else 
	log "Sozdanie virtualnogo ocruzhenia"
fi

. .venv/bin/activate
check "Ne udalos activirovat virtualnoe ocruzhenie"

#4 Install Python - zavisimosti

log "Install Python - zavis is requirements.txt..."

if [ ! -f "requirements.txt" ]; then
	error "File requirements.txt ne naiden v ${APP_DIR}"
fi

pip install --upgrade pip -q 
check "Ne udalos install zavisimosti is requirements.txt"

log "zavisimosti install"

#5 Podgotovka PostgreSQL

log "Setting PostgreSQL..."

if command -v systemctl >/dev/null 2>&1; then
	sudo systemctl start postgresql 2>/dev/null || true 
	sudo systemctl enable postgresql 2>/dev/null || true 
fi 

log "Wait gotovnosti PostgreSQl..."
for i in 1 2 3 4 5 6 7 8 9 10; do 
	if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then 
		break
	fi
	if ["$i" -eq 10 ]; then 
		error "PostgreSQL ne otvechaet after wait"
	fi 
	sleep 1 
done 

log "Create BD and user (if not create)..."

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1\
	|| sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1\
	|| sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

sudo -u postgres psql -d "${DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${DB_USER};" 2>/dev/null || true
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT CREATE ON SCHEMA public TO ${DB_USER};" 2>/dev/null || true 
sudo -u postgres psql -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};" 2>/dev/null || true
sudo -u postgres psql -d "${DB_NAME}" -c "ALTER SCHEMA public OWNER TO ${DB_USER};" 2>/dev/null || true 

log "BD ${DB_NAME} and user ${DB_USER} gotovy"

#6 Start app

log "Start FastAPI-app..."

if command -v fuser >/dev/null 2>&1; then 
	fuser -k "${APP_PORT}/tcp" 2>/dev/null || true 
elif command -v lsof >/dev/null  2>&1; then 
	PID=$(lsof -t -i:"${APP_PORT}" 2>/dev/null || true)
	if [ -n "$PID" ]; then 
		kill "$PID" 2>/dev/null || true 
		sleep 1 
	fi
fi

nohup .venv/bin/uvicorn app.main:app  --host 0.0.0.0 --port 8000 > /tmp/taskboard.log 2>&1 &

UVICORN_PID=$!
log "Uvicorn zapushen (PID: ${UVICORN_PID})"

#7 Proverca rezultata razvertyvania

log "Ozhidanie gotovnosty app..."

SUCCESS=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do 
	if curl -sf "${HEALTH_URL}" >/dev/null 2>&1; then 
		SUCCESS=1
		break
	fi
	if ! kill -0 "${UVICORN_PID}" 2>/dev/null; then
		echo "[ERROR] process uvicorn zaverchilsa. Log:"
		tail -n 30 /tmp/${APP_NAME}.log 2>/dev/null || true 
		error "Prilozhenie ne zapustilos"
fi 
sleep 1 
done 

if [ "$SUCCESS" -ne 1 ]; then
	echo "[ERROR] Healthcheck ne proshel. Log:"
	tail -n 30 /tmp/${APP_NAME}.log 2>/dev/null || true 
	error "App dont answer na ${HEALTH_URL}"
fi 

echo ""
echo " Application deployed successfully."
echo " Application is available at: http://localhost:${APP_PORT}"
echo " Swagger UI:                  http://localhost:${APP_PORT}/docs"
echo " Healthcheck:                 ${HEALTH_URL}"
echo ""
echo "Log app: /tmp/${APP_NAME}.log"
echo "Ostanovit: kill ${UVICORN_PID}"
echo ""

