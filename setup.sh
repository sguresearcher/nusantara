#!/bin/bash

# =========================
# T-Guard Version
# =========================
TGUARD_VERSION="1.2"

# Root dir (agar path konsisten walau user menjalankan dari folder lain)
ROOT_DIR="$(pwd)"

# =========================
# UI Helpers
# =========================
print_version_line() {
  echo -e "\e[1;35mT-Guard Version ${TGUARD_VERSION}\e[0m"
}

print_step_header() {
  # usage: print_step_header "Installing Wazuh (SIEM)"
  echo
  echo -e "\e[1;32m=================================================================\e[0m"
  echo -e "\e[1;32m T-Guard SOC Package — $1 \e[0m"
  print_version_line
  echo -e "\e[1;32m=================================================================\e[0m"
  echo
}

die() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
ok() { echo -e "\e[1;32m[OK]\e[0m    $*"; }

need_dir() { [[ -d "$1" ]] || die "Direktori tidak ditemukan: $1"; }
need_file() { [[ -f "$1" ]] || die "File tidak ditemukan: $1"; }

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    sudo cp -f "$f" "${f}.bak.${ts}"
    info "Backup dibuat: ${f}.bak.${ts}"
  fi
}

# Banner
print_banner() {
    echo -e "\n\e[1;38;2;255;69;0m"
    echo "|.___---___.||     ___________        ________                       .___   "
    echo "|     |     ||     \__    ___/       /  _____/ __ _______ _______  __| _/   "
    echo "|     |     ||       |    |  ______ /   \  ___|  |  \__  \\\\_  __ \\/ __ | "
    echo "|-----o-----||       |    | /_____/ \    \_\  \  |  // __ \|  | \\/ /_/ |   "
    echo ":     |     ::       |____|          \______  /____/(____  /__|  \____ |    "
    echo " \    |    //                               \/           \/           \/    "
    echo "  '.__|__.'          			Start Your Defence."
    echo "                        	        Build Your Fortress."
    echo "                         		T-Guard Version 1.2"
    echo -e "\e[0m"
}

# Function for Update System and Install Prerequisites
update_install_pre() {
    echo
    echo -e "\e[1;32m -- Step 1: Update System and Install Prerequisites -- \e[0m"
    echo
    echo -e "\e[1;36m--> Updating System and Install Prerequisites...\e[0m"
    echo
    sudo apt-get update -y
    sudo apt-get upgrade -y
    sudo apt-get install wget curl nano git unzip nodejs -y
    sudo apt install -y whiptail jq
    echo
    echo -e "\e[1;36m--> Installing Docker...\e[0m"
    echo
    
    # Check if Docker is installed
    if command -v docker > /dev/null; then
        echo "Docker is already installed."
    else
        # Install Docker
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo systemctl enable docker.service && sudo systemctl enable containerd.service
    fi
    echo
    echo -e "\e[1;32m Step 1 Completed \e[0m"
}

# Function for Install all module: MISP, Wazuh, IRIS, Shuffle
install_module() {
    echo
    echo -e "\e[1;32m -- Step 2: Install T-Guard SOC Package -- \e[0m"
    echo

    # --- Initial Network Configuration ---    
    # Ask the user for the network environment just once.
    echo "Please select the network environment for this installation."
    PS3=$'\nChoose an option: '
    select network_env in "Private Network (local VM: VirtualBox, VMware, etc.)" "Public Network (cloud server: GCP, AWS, Azure, etc.)" "Back"; do
        case $REPLY in
            1)
                # Get the primary private IP address
                IP_ADDRESS=$(hostname -I | awk '{print $1}')
                echo
                echo -e "\e[1;34m[INFO] Private IP Address:\e[1;33m $IP_ADDRESS\e[0m"
                break
                ;;

            2)
                # Get the public IP address
                IP_ADDRESS=$(curl -s ip.me -4)
                echo
                echo -e "\e[1;34m[INFO] Public IP Address:\e[1;33m $IP_ADDRESS\e[0m"
                break
                ;;

            3)
                echo "back to main menu..."
                return # Exits the function and goes back to the main script menu
                ;;

            *)
                echo "Invalid option. Please try again."
                ;;

        esac
    done

    # Validate that an IP address was successfully retrieved
    if [ -z "$IP_ADDRESS" ]; then
        echo -e "\e[1;31m[ERROR] Could not determine IP address. Aborting installation.\e[0m"
        return
    fi

    echo -e "\e[1;34m[INFO] Using IP Address \e[1;33m$IP_ADDRESS\e[1;34m for all subsequent configurations.\e[0m\n"


    # --- 1. Installing Wazuh (SIEM) & Deploying Agent ---
    print_step_header "Installing Wazuh (SIEM)"
    cd wazuh-docker/single-node
    sudo docker compose -f generate-indexer-certs.yml run --rm generator
    sudo docker compose up -d

    # Check Wazuh Status
    containers=("single-node-wazuh.dashboard-1" "single-node-wazuh.manager-1" "single-node-wazuh.indexer-1")
    for container in "${containers[@]}"; do
        running_status=$(sudo docker inspect --format='{{.State.Running}}' $container 2>/dev/null)
        if [ "$running_status" != "true" ]; then
            echo -e "\e[1;31m[ERROR] Wazuh installation failed: Container '$container' is not running.\e[0m"
            # Attempt to show logs for debugging
            echo -e "\e[1;33mDisplaying logs for $container:\e[0m"
            sudo docker logs $container --tail 50
            exit 1
        fi
    done
    echo -e "\e[1;32mYour Wazuh installation is successful and all core containers are running.\e[0m"

    # Deploy Wazuh Agent automatically
    echo -e "\e[1;36m--> Automatically deploying Wazuh Agent...\e[0m"
    wazuh_version=$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep '^wazuh/wazuh-dashboard:' | head -n 1 | cut -d':' -f2)
    
    if [ -z "$wazuh_version" ]; then
        echo -e "\e[1;31m[ERROR] Could not determine Wazuh version from Docker images.\e[0m"
        exit 1
    fi

    wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${wazuh_version}-1_amd64.deb -O wazuh-agent.deb
    
    # Install using the pre-configured IP and agent name
    sudo WAZUH_MANAGER="$IP_ADDRESS" WAZUH_AGENT_NAME="001-tguard-agent" dpkg -i ./wazuh-agent.deb
    sudo systemctl daemon-reload
    sudo systemctl enable wazuh-agent
    sudo systemctl start wazuh-agent
    echo -e "\e[1;32mWazuh Agent deployed successfully.\e[0m"

    cd ../..

    # --- 2. Installing Shuffle (SOAR) ---
    print_step_header "Installing Shuffle (SOAR)"
  
    cd shuffle
    mkdir -p shuffle-database 
    sudo chown -R 1000:1000 shuffle-database
    sudo swapoff -a
    sudo docker compose up -d
    sudo docker restart shuffle-opensearch
    echo -e "\e[1;32mShuffle deployment initiated.\e[0m"
    
    # Check Shuffle Status
    echo -e "\e[1;34m[INFO] Verifying Shuffle container status...\e[0m"
    shuffle_containers=("shuffle-backend" "shuffle-orborus" "shuffle-frontend")
    for container in "${shuffle_containers[@]}"; do
        sleep 10
        running_status=$(sudo docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null)
        if [ "$running_status" != "true" ]; then
            echo -e "\e[1;31m[ERROR] Shuffle installation failed: Container '$container' is not running.\e[0m"
            echo -e "\e[1;33mDisplaying logs for $container:\e[0m"
            sudo docker logs "$container" --tail 50
            exit 1
        fi
    done
    echo
    echo -e "\e[1;32mShuffle deployment is successful and all core containers are running.\e[0m"
    cd ..
    
    # --- 3. Installing DFIR-IRIS (Incident Response Platform) ---
    print_step_header "Installing DFIR-IRIS (Incident Response)"
    cd iris-web
    sudo docker compose pull
    sudo docker compose up -d     
    echo -e "\e[1;32mDFIR-IRIS deployment initiated.\e[0m"

    # Check DFIR-IRIS Status
    echo -e "\e[1;34m[INFO] Verifying DFIR-IRIS container status...\e[0m"
    iris_containers=("iriswebapp_nginx" "iriswebapp_worker" "iriswebapp_app" "iriswebapp_db" "iriswebapp_rabbitmq")
    for container in "${iris_containers[@]}"; do
        sleep 10
        running_status=$(sudo docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null)
        if [ "$running_status" != "true" ]; then
            echo -e "\e[1;31m[ERROR] DFIR-IRIS installation failed: Container '$container' is not running.\e[0m"
            echo -e "\e[1;33mDisplaying logs for $container:\e[0m"
            sudo docker logs "$container" --tail 50
            exit 1
        fi
    done
    echo
    echo -e "\e[1;32mDFIR-IRIS deployment is successful and all core containers are running.\e[0m"
        # Restart iriswebapp_app to ensure full initialization
    echo -e "\e[1;34m[INFO] Restarting iriswebapp_app container...\e[0m"
    sudo docker restart iriswebapp_app

    echo -e "\e[1;34m[INFO] Waiting 60 seconds for iriswebapp_app to stabilize...\e[0m"
    sleep 60

    # Final sanity check after restart
    running_status=$(sudo docker inspect --format='{{.State.Running}}' iriswebapp_app 2>/dev/null)
    if [ "$running_status" != "true" ]; then
        echo -e "\e[1;31m[ERROR] iriswebapp_app failed after restart.\e[0m"
        sudo docker logs iriswebapp_app --tail 50
        continue
    fi

    cd ..

   # --- 4. Installing MISP (Threat Intelligence) ---
    print_step_header "Installing MISP (Threat Intelligence)"
    cd misp-docker
    
    # Configure MISP environment
    sed -i "s|BASE_URL=.*|BASE_URL='https://$IP_ADDRESS:1443'|" template.env
    sed -i 's|^CORE_HTTP_PORT=.*|CORE_HTTP_PORT=8081|' template.env
    sed -i 's|^CORE_HTTPS_PORT=.*|CORE_HTTPS_PORT=1443|' template.env
    cp template.env .env
    
    echo -e "\e[1;34m[INFO] Starting MISP containers...\e[0m"
    sudo docker compose up -d 2>/dev/null
    sudo docker restart misp-docker-db-1
    sudo docker restart misp-docker-misp-core-1
      
    echo -e "\e[1;34m[INFO] Waiting 5 minutes for MISP to fully initialize...\e[0m"
    sleep 300

# Get the actual database container name
DB_CONTAINER=$(sudo docker ps --filter "name=db" --filter "ancestor=mariadb" --format "{{.Names}}" | grep misp | head -1)

# Jika DB container tidak ditemukan, jangan bikin ribet & jangan stop script
if [ -z "$DB_CONTAINER" ]; then
    echo -e "\e[1;33m[WARN] MISP DB container (mariadb) tidak ditemukan. Skip konfigurasi DB & restart MISP, lanjut step berikutnya.\e[0m"
else
    echo -e "\e[1;34m[INFO] Found database container: $DB_CONTAINER\e[0m"
    echo -e "\e[1;34m[INFO] Waiting for MariaDB to initialize...\e[0m"

    max_attempts=60
    attempt=0
    db_ready=false

    while [ $attempt -lt $max_attempts ]; do
        if sudo docker logs "$DB_CONTAINER" 2>&1 | grep -q "ready for connections"; then
            echo -e "\e[1;32m[OK] Database is ready for connections!\e[0m"
            db_ready=true
            break
        fi

        # progress setiap 5 detik
        if [ $((attempt % 5)) -eq 0 ]; then
            echo -e "\e[1;33m[WAIT] Database masih init... ($attempt detik)\e[0m"
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    # kalau DB tidak ready, jangan exit — cukup warning dan lanjut
    if [ "$db_ready" = false ]; then
        echo -e "\e[1;33m[WARN] Database belum ready setelah $max_attempts detik. Skip konfigurasi user DB, lanjut step berikutnya.\e[0m"
    else
        echo -e "\e[1;34m[INFO] Database ready, waiting 5 seconds...\e[0m"
        sleep 5

        # Get MySQL password from .env file (kalau kosong, warning dan skip)
        MYSQL_PASSWORD=$(grep "^MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2)

        if [ -z "$MYSQL_PASSWORD" ]; then
            echo -e "\e[1;33m[WARN] MYSQL_PASSWORD tidak ditemukan di .env. Skip konfigurasi user DB, lanjut.\e[0m"
        else
            echo -e "\e[1;34m[INFO] Configuring database users and permissions...\e[0m"
            sudo docker exec -i "$DB_CONTAINER" mysql -u root -p"$MYSQL_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS misp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'misp'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
CREATE USER IF NOT EXISTS 'misp'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON misp.* TO 'misp'@'localhost';
GRANT ALL PRIVILEGES ON misp.* TO 'misp'@'%';
FLUSH PRIVILEGES;
EOF

            # kalau gagal, jangan exit — warning dan lanjut
            if [ $? -eq 0 ]; then
                echo -e "\e[1;32m[OK] Database users configured successfully.\e[0m"
            else
                echo -e "\e[1;33m[WARN] Failed to configure database users. Skip dan lanjut.\e[0m"
            fi
        fi

        # Restart containers (jangan exit kalau gagal)
        echo -e "\e[1;34m[INFO] Restarting MISP containers...\e[0m"
        sudo docker restart "$DB_CONTAINER" >/dev/null 2>&1 || \
            echo -e "\e[1;33m[WARN] Gagal restart DB container. Lanjut.\e[0m"
        sleep 5

        MISP_CORE=$(sudo docker ps --filter "name=misp-core" --format "{{.Names}}" | head -1)
        MISP_MODULES=$(sudo docker ps --filter "name=misp-modules" --format "{{.Names}}" | head -1)

        if [ -n "$MISP_CORE" ]; then
            sudo docker restart "$MISP_CORE" >/dev/null 2>&1 || \
                echo -e "\e[1;33m[WARN] Gagal restart $MISP_CORE. Lanjut.\e[0m"
        fi

        if [ -n "$MISP_MODULES" ]; then
            sudo docker restart "$MISP_MODULES" >/dev/null 2>&1 || \
                echo -e "\e[1;33m[WARN] Gagal restart $MISP_MODULES. Lanjut.\e[0m"
        fi

        echo -e "\e[1;32mMISP deployment initiated.\e[0m"

        # Check MISP Status (jangan exit kalau ada yang mati; tampilkan warning & lanjut)
        echo -e "\e[1;34m[INFO] Verifying MISP container status...\e[0m"

        MISP_CORE=$(sudo docker ps -a --filter "name=misp-core" --format "{{.Names}}" | head -1)
        MISP_MODULES=$(sudo docker ps -a --filter "name=misp-modules" --format "{{.Names}}" | head -1)
        MISP_MAIL=$(sudo docker ps -a --filter "name=mail" --format "{{.Names}}" | grep misp | head -1)
        MISP_REDIS=$(sudo docker ps -a --filter "name=redis" --format "{{.Names}}" | grep misp | head -1)

        misp_containers=("$DB_CONTAINER" "$MISP_CORE" "$MISP_MODULES" "$MISP_MAIL" "$MISP_REDIS")

        for container in "${misp_containers[@]}"; do
            [ -z "$container" ] && continue

            sleep 2
            running_status=$(sudo docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null)

            if [ "$running_status" != "true" ]; then
                echo -e "\e[1;33m[WARN] Container '$container' tidak running. Lihat logs terakhir:\e[0m"
                sudo docker logs "$container" --tail 50 2>/dev/null
                # lanjut tanpa exit
            fi
        done

        echo -e "\e[1;32m[INFO] Verifikasi container selesai (non-blocking).\e[0m"

        # Monitor MISP initialization (opsional; jangan bikin script berhenti)
        echo -e "\e[1;34m[INFO] Monitoring MISP initialization...\e[0m"
        echo -e "\e[1;33m[TIP] Ctrl+C untuk skip monitoring.\e[0m"

        if [ -n "$MISP_CORE" ]; then
            timeout=300
            elapsed=0
            while [ $elapsed -lt $timeout ]; do
                if sudo docker logs "$MISP_CORE" 2>&1 | grep -q "INIT | Database initialized"; then
                    echo -e "\e[1;32m[OK] MISP database initialization completed!\e[0m"
                    break
                elif sudo docker logs "$MISP_CORE" 2>&1 | grep -q "ERROR.*Table.*doesn't exist"; then
                    echo -ne "\e[1;33m[WAIT] Masih init schema... ($elapsed detik)\r\e[0m"
                fi
                sleep 5
                elapsed=$((elapsed + 5))
            done
            echo ""
        fi
    fi
fi
    cd ..

    echo
    echo -e "\e[1;32m Step 2 Completed: All T-Guard SOC packages have been deployed. \e[0m"

    # Wait the initialization
    echo -e "\e[1;34m[INFO] Waiting for 60 seconds for all services to initialize properly...\e[0m"
    
    for i in $(seq 60 -1 0); do
        # The '-ne' and '\r' ensure the countdown happens on a single, updating line.
        echo -ne "Time remaining: $i seconds \r"
        sleep 1
    done

    # --- Access Information ---
    BLUE='\e[1;34m'
    YELLOW='\e[1;33m'
    GREEN='\e[1;32m'
    WHITE='\e[1;37m'
    NC='\e[0m'

    printf "\n"
    printf "${GREEN}+----------------------------------------------------------------------+\n"
    printf "|${WHITE}      T-Guard SOC Package - Dashboard Access Default Credentials      ${GREEN}|\n"
    printf "|${WHITE}                         T-Guard Version ${TGUARD_VERSION}                         ${GREEN}|\n"
    printf "+----------------------------------------------------------------------+\n"

    printf "  ${BLUE}%-18s ${YELLOW}%-49s ${GREEN}\n" "MISP (Threat Intel)" "https://${IP_ADDRESS}:1443"
    printf "  ${WHITE}%-18s ${NC}%-49s ${GREEN}\n" " ├─ Username" "admin@admin.test"
    printf "  ${WHITE}%-18s ${NC}%-49s ${GREEN}\n" " └─ Password" "admin"
    printf "${GREEN}+----------------------------------------------------------------------+\n"

    printf "  ${BLUE}%-18s ${YELLOW}%-49s ${GREEN}\n" "Wazuh (SIEM)" "https://${IP_ADDRESS}"
    printf "  ${WHITE}%-18s ${NC}%-49s ${GREEN}\n" " ├─ Username" "admin"
    printf "  ${WHITE}%-18s ${NC}%-49s ${GREEN}\n" " └─ Password" "SecretPassword"
    printf "${GREEN}+----------------------------------------------------------------------+\n"

    printf "  ${BLUE}%-18s ${YELLOW}%-49s ${GREEN}\n" "DFIR-IRIS (IR)" "https://${IP_ADDRESS}:8443"
    printf "  ${WHITE}%-18s ${NC}%-49s ${GREEN}\n" " ├─ Username" "administrator"
    printf "  ${WHITE}%-18s ${NC}%-49s ${GREEN}\n" " └─ Password" "MySuperAdminPassword!"
    printf "${GREEN}+----------------------------------------------------------------------+\n"

    printf "  ${BLUE}%-18s ${YELLOW}%-49s ${GREEN}\n" "Shuffle (SOAR)" "http://${IP_ADDRESS}:3001"
    printf "${GREEN}+----------------------------------------------------------------------+\n\n"

    ok "Step 2 Completed: All T-Guard SOC packages have been deployed."
}

# =========================
# Step 3: Integrations
# =========================

# Integrate modules and Perform other configurations
integrate_module() {
    echo
    echo -e "\e[1;32m -- Step 3: Perform Integrations -- \e[0m"
    echo
    
    SRC_DIR="${ROOT_DIR}/wazuh-docker/single-node/custom-integrations"

    VOL_INTEGRATIONS="/var/lib/docker/volumes/single-node_wazuh_integrations/_data"
    VOL_ETC="/var/lib/docker/volumes/single-node_wazuh_etc/_data"
    VOL_RULES="/var/lib/docker/volumes/single-node_wazuh_etc/_data/rules"

    MANAGER_CONTAINER="single-node-wazuh.manager-1"
    WAZUH_COMPOSE_DIR="${ROOT_DIR}/wazuh-docker/single-node"

    # Required files
    need_file "${SRC_DIR}/custom-misp.py"
    need_file "${SRC_DIR}/custom-wazuh_iris.py"
    need_file "${SRC_DIR}/local_rules.xml"
    need_file "${SRC_DIR}/ossec.conf"

    # VirusTotal active response + agent config requirements
    need_file "${SRC_DIR}/remove-threat.sh"
    need_file "${SRC_DIR}/add_vtwazuh_config-agent.conf"

    # Required volumes
    sudo test -d "$VOL_INTEGRATIONS" || die "Volume integrations tidak ada: $VOL_INTEGRATIONS"
    sudo test -d "$VOL_ETC" || die "Volume etc tidak ada: $VOL_ETC"
    sudo test -d "$VOL_RULES" || die "Volume rules tidak ada: $VOL_RULES"

    # Input keys/urls
    echo
    info "Masukkan parameter patch untuk ossec.conf (di volume Wazuh)."
    read -r -p "IRIS Base URL (contoh: https://10.10.10.10 atau https://iris.domain): " IRIS_BASE_URL
    read -r -p "IRIS API Key: " IRIS_API_KEY
    read -r -p "Shuffle Webhook URL (FULL, contoh: https://.../hooks/...): " SHUFFLE_WEBHOOK_URL
    read -r -p "VirusTotal API Key: " VT_API_KEY

    # Auto IP untuk default (karena integrate_module bisa dijalankan terpisah dari Step 2)
    DEFAULT_IP="$(hostname -I | awk '{print $1}')"
    DEFAULT_MISP_URL="https://${DEFAULT_IP}:1443"
    DEFAULT_WAZUH_URL="https://${DEFAULT_IP}"

    echo
    info "Parameter untuk patch custom integrations (Python)."

    read -r -p "MISP Base URL (default: ${DEFAULT_MISP_URL}): " MISP_BASE_URL
    MISP_BASE_URL="${MISP_BASE_URL:-$DEFAULT_MISP_URL}"
    MISP_BASE_URL="${MISP_BASE_URL%/}"

    read -r -p "MISP API Key: " MISP_API_KEY

    read -r -p "Wazuh Dashboard URL (default: ${DEFAULT_WAZUH_URL}): " WAZUH_DASHBOARD_URL
    WAZUH_DASHBOARD_URL="${WAZUH_DASHBOARD_URL:-$DEFAULT_WAZUH_URL}"
    WAZUH_DASHBOARD_URL="${WAZUH_DASHBOARD_URL%/}"

    IRIS_BASE_URL="${IRIS_BASE_URL%/}"

    # Backup existing volume files (jika ada)
    echo
    info "Backup existing files in volumes (if any)..."
    backup_if_exists "${VOL_INTEGRATIONS}/custom-misp.py"
    backup_if_exists "${VOL_INTEGRATIONS}/custom-wazuh_iris.py"
    backup_if_exists "${VOL_RULES}/local_rules.xml"
    backup_if_exists "${VOL_ETC}/ossec.conf"
    backup_if_exists "${VOL_ETC}/active-response/bin/remove-threat.sh"

    # Copy phase (integrations + rules + ossec.conf)
    echo
    info "Copy integration files to Docker volumes..."
    sudo cp -f "${SRC_DIR}/custom-misp.py"        "${VOL_INTEGRATIONS}/custom-misp.py"
    sudo cp -f "${SRC_DIR}/custom-wazuh_iris.py"  "${VOL_INTEGRATIONS}/custom-wazuh_iris.py"
    sudo cp -f "${SRC_DIR}/local_rules.xml"       "${VOL_RULES}/local_rules.xml"
    sudo cp -f "${SRC_DIR}/ossec.conf"            "${VOL_ETC}/ossec.conf"
    ok "Files copied to volumes."

    # Patch ossec.conf in volume
    echo
    info "Patching ossec.conf in volume..."
    OSSEC_VOL_FILE="${VOL_ETC}/ossec.conf"
    sudo test -f "$OSSEC_VOL_FILE" || die "ossec.conf tidak ada di volume: $OSSEC_VOL_FILE"

    # IRIS block (name: custom-wazuh_iris.py)
    sudo sed -i \
      -e "/<name>custom-wazuh_iris\.py<\/name>/,/<\/integration>/ s|<hook_url>.*</hook_url>|<hook_url>${IRIS_BASE_URL}/alerts/add</hook_url>|" \
      -e "/<name>custom-wazuh_iris\.py<\/name>/,/<\/integration>/ s|<api_key>.*</api_key>|<api_key>${IRIS_API_KEY}</api_key>|" \
      "$OSSEC_VOL_FILE"

    # Shuffle block (name: shuffle)
    sudo sed -i \
      -e "/<name>shuffle<\/name>/,/<\/integration>/ s|<hook_url>.*</hook_url>|<hook_url>${SHUFFLE_WEBHOOK_URL}</hook_url>|" \
      "$OSSEC_VOL_FILE"

    # VirusTotal block (name: virustotal)
    sudo sed -i \
      -e "/<name>virustotal<\/name>/,/<\/integration>/ s|<api_key>.*</api_key>|<api_key>${VT_API_KEY}</api_key>|" \
      "$OSSEC_VOL_FILE"

    ok "ossec.conf patched."

    # Patch Python integrations
    echo
    info "Patching Python integration files..."
    
    # Patch custom-misp.py
    sudo sed -i \
      -e "s|misp_base_url = .*|misp_base_url = '${MISP_BASE_URL}'|" \
      -e "s|misp_api_key = .*|misp_api_key = '${MISP_API_KEY}'|" \
      "${VOL_INTEGRATIONS}/custom-misp.py"
    
    # Patch custom-wazuh_iris.py
    sudo sed -i \
      -e "s|wazuh_dashboard_url = .*|wazuh_dashboard_url = '${WAZUH_DASHBOARD_URL}'|" \
      "${VOL_INTEGRATIONS}/custom-wazuh_iris.py"

    ok "Python integration files patched."

    # --- IRIS DB + Python deps on Manager
    echo
    info "IRIS DB bootstrap + install python deps on Wazuh Manager..."
    sudo docker exec -i iriswebapp_db psql -U postgres -d iris_db -c \
      "INSERT INTO user_client (id, user_id, client_id, access_level, allow_alerts) VALUES (1, 1, 1, 4, 't');" || true

    # Pastikan container manager benar
    sudo docker inspect "$MANAGER_CONTAINER" >/dev/null 2>&1 || die "Container tidak ditemukan: $MANAGER_CONTAINER"

    sudo docker exec -ti "$MANAGER_CONTAINER" yum install -y python3-pip || true
    sudo docker exec -ti "$MANAGER_CONTAINER" pip3 install requests || true

    # ==========================================================
    # VirusTotal <-> Wazuh: Active Response + Agent Setup
    # ==========================================================
    echo
    info "VirusTotal integration: deploying remove-threat.sh to Manager + Agent setup..."

    # Copy remove-threat.sh to manager active-response bin
    sudo docker cp "${SRC_DIR}/remove-threat.sh" "${MANAGER_CONTAINER}:/var/ossec/active-response/bin/remove-threat.sh" \
    || die "Gagal docker cp remove-threat.sh ke manager container"

    # Verifikasi singkat
    sudo docker exec -t "$MANAGER_CONTAINER" ls -lah /var/ossec/active-response/bin/remove-threat.sh >/dev/null 2>&1 \
    && ok "remove-threat.sh deployed to ${MANAGER_CONTAINER}:/var/ossec/active-response/bin/" \
    || info "File belum terverifikasi di path target, cek manual."

    # 1) Agent setup: patch USECASE_DIR then append config to host agent ossec.conf
    USECASE_DIR="${ROOT_DIR}/usecase/webdeface"
    AGENT_OSSEC="/var/ossec/etc/ossec.conf"
    AGENT_CFG_TMP="/tmp/add_vtwazuh_config-agent.conf"

    if [[ ! -d "$USECASE_DIR" ]]; then
        info "USECASE_DIR tidak ditemukan di host: $USECASE_DIR (pastikan folder usecase/webdeface ada)."
    fi

    # Siapkan file agent conf sementara
    cp -f "${SRC_DIR}/add_vtwazuh_config-agent.conf" "$AGENT_CFG_TMP"

    # Replace placeholder $USECASE_DIR pada file config agent
    sed -i "s|<directories report_changes=\"yes\" whodata=\"yes\" realtime=\"yes\">\$USECASE_DIR</directories>|<directories report_changes=\"yes\" whodata=\"yes\" realtime=\"yes\">${USECASE_DIR}</directories>|" \
      "$AGENT_CFG_TMP"

    # Append ke agent ossec.conf (host)
    if [[ -f "$AGENT_OSSEC" ]]; then
        sudo bash -c "cat '$AGENT_CFG_TMP' >> '$AGENT_OSSEC'"
        ok "Agent ossec.conf updated: appended VT syscheck directories."
    else
        info "Agent ossec.conf tidak ditemukan di $AGENT_OSSEC. Lewati agent append."
    fi

    # Restart host agent (jika ada)
    if systemctl list-unit-files | grep -q "^wazuh-agent"; then
        sudo systemctl restart wazuh-agent
        ok "Host wazuh-agent restarted."
    else
        info "wazuh-agent service tidak ditemukan di host. Lewati restart agent."
    fi

    # Apply permissions inside manager container (integrations + rules + ossec + active-response)
    echo
    info "Applying permissions inside Wazuh manager container..."
    sudo docker exec -ti "$MANAGER_CONTAINER" chown root:wazuh /var/ossec/integrations/custom-misp.py || true
    sudo docker exec -ti "$MANAGER_CONTAINER" chown root:wazuh /var/ossec/integrations/custom-wazuh_iris.py || true
    sudo docker exec -ti "$MANAGER_CONTAINER" chmod 750 /var/ossec/integrations/custom-misp.py || true
    sudo docker exec -ti "$MANAGER_CONTAINER" chmod 750 /var/ossec/integrations/custom-wazuh_iris.py || true

    sudo docker exec -ti "$MANAGER_CONTAINER" chown wazuh:wazuh /var/ossec/etc/rules/local_rules.xml || true
    sudo docker exec -ti "$MANAGER_CONTAINER" chmod 550 /var/ossec/etc/rules/local_rules.xml || true

    sudo docker exec -ti "$MANAGER_CONTAINER" chown root:wazuh /var/ossec/etc/ossec.conf || true
    sudo docker exec -ti "$MANAGER_CONTAINER" chmod 640 /var/ossec/etc/ossec.conf || true

    # Active-response perms on manager (location=local -> manager butuh file ini)
    sudo docker exec -ti "$MANAGER_CONTAINER" chown root:wazuh /var/ossec/active-response/bin/remove-threat.sh || true
    sudo docker exec -ti "$MANAGER_CONTAINER" chmod 750 /var/ossec/active-response/bin/remove-threat.sh || true

    ok "Permissions applied."

    # Restart wazuh stack
    echo
    info "Restarting Wazuh stack..."
    pushd "$WAZUH_COMPOSE_DIR" >/dev/null
    sudo docker compose restart
    popd >/dev/null

    ok "Step 3 Completed: Integrations deployed (copy + patch + VT active-response + agent setup + restart)."
}

# =========================
# Step 4: PoC Menu
# =========================

poc_menu() {
    echo
    echo -e "\e[1;32m -- Step 4: Run Proof of Concept (PoC) Use Cases -- \e[0m"
    echo
    
    while true; do
        echo -e "\n\e[1;32m--- PoC Menu ---\e[0m"
        PS3="Choose a PoC to run: "
        select opt in "Brute Force Detection" "Malware Detection" "Web Defacement Detection" "Return to Main Menu"; do
            case $REPLY in
                1)
                    # --- PoC: Brute Force Detection ---
                    echo -e "\n\e[1;36m--- Simulating SSH Brute Force Attack --- \e[0m"
                    
                    echo -e "\e[1;34m[INFO] This will simulate 10 failed login attempts to trigger Wazuh alerts. \e[1;33mSimply enter any value in the password field.\e[0m"
                    echo
                    IP=$(curl -s ip.me -4 || hostname -I | awk '{print $1}')
                    echo -e "\e[1;34m[INFO] Target IP Address: $IP\e[0m"
                    
                    for i in $(seq 1 10); do
                        echo "Simulating Brute Force: Attempt $i..."
                        # BatchMode=yes prevents password prompts, ensuring the attempt fails automatically
                        ssh -o BatchMode=yes -o ConnectTimeout=5 "fakeuser@$IP" 2>/dev/null
                        sleep 1
                    done
                    
                    echo -e "\n\e[1;32m Brute force simulation complete. Check your Wazuh dashboard for alerts\e[0m"
                    break
                    ;;
                2)
                    # --- PoC: Malware Detection ---
                    echo -e "\n\e[1;36m--- Simulating Malware Detection --- \e[0m"
                    echo -e "\e[1;34m[INFO] Downloading the EICAR test file. This is a HARMLESS file used to test antivirus software.\e[0m"
                    
                    sudo curl -Lo /root/eicar.com https://secure.eicar.org/eicar.com && sudo ls -lah /root/eicar.com
                    echo -e "\e[1;34m[INFO] EICAR file downloaded to /root/eicar.com\e[0m"
                    echo
                    
                    echo -e "\n\e[1;32m Malware simulation complete. Check your Wazuh dashboard for alerts related to active response and VirusTotal.\e[0m"
                    break
                    ;;
                3)
                    # --- PoC: Web Defacement Detection ---
                    echo -e "\n\e[1;36m--- Simulating Web Defacement --- \e[0m"
                                    
                    cd usecase/webdeface
                    IP=$(curl -s ip.me -4 || hostname -I | awk '{print $1}')
                    sudo sed -i -e "s/(your_vm_ip)/$IP/g" ./server.js
                    
                    echo -e "\e[1;34m[INFO] Starting a temporary web server...\e[0m"
                    nohup node server.js > server.log 2>&1 &
                    WEBSERVER_PID=$!
                    
                    echo -e "\n\e[1;33mAction Required: Before we simulate the defacement, please visit your website at:\e[0m http://$IP:3000"
                    read -p "Ready to perform the web defacement? (y/n) " -r
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        echo "Operation cancelled. Shutting down web server."
                        kill $WEBSERVER_PID
                        cd ../..
                        break
                    fi

                    cat webdeface.html > index.html
                    echo -e "\n\e[1;31m[ATTACK] Your website has been defaced! Refresh your browser to see the change.\e[0m"
                    echo -e "\e[1;34m[INFO] Check your Wazuh dashboard for file integrity alerts.\e[0m"
                    
                    read -p "Do you want to recover the website? (y/n) " -r
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        cat index_ori.html > index.html
                        echo -e "\e[1;32m Your website has been recovered.\e[0m"
                    fi
                    
                    read -p "Do you want to shut down the temporary web server? (y/n) " -r
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        echo -e "\e[1;34m[INFO] Shutting down web server...\e[0m"
                        kill $WEBSERVER_PID
                        echo -e "\e[1;32m Web server is off.\e[0m"
                    else
                         echo "OK. The web server is still running at http://$IP:3000"
                    fi
                    cd ../..
                    break
                    ;;
                4)
                    echo "Returning to main menu..."
                    return
                    ;;
                *)
                    echo "Invalid option. Please try again."
                    ;;
            esac
        done
    done
}

# =========================
# Main Menu Loop
# =========================

while true; do
    print_banner
    echo -e "\n\e[1;32m--- Main Menu ---\e[0m"
    PS3=$'\nChoose an option: '

    COLUMNS=1 

    select opt in "Step 1: Update and Install Prerequisites" "Step 2: Install T-Guard SOC Package" "Step 3: Integrate T-Guard SOC Package" "Step 4: Run Proof of Concept (PoC)" "Exit"; do
        case $REPLY in
            1) update_install_pre ; break ;;
            2) install_module ; break ;;
            3) integrate_module ; break ;;
            4) poc_menu ; break ;;
            5) echo "See you later!" ; exit ;;
            *) echo "Invalid option. Try again." ;;
        esac
    done
done
