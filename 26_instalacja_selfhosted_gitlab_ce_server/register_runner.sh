#!/bin/bash
set -euo pipefail

###############################################################################
# SEKCJA KONFIGURACJI - DOSTOSUJ DO SWOICH POTRZEB
###############################################################################

# Token rejestracyjny runnera
# Jak uzyskać: Admin Area → CI/CD → Runners → "Create instance runner"
#              Zdefiniuj tagi (np. docker), kliknij "Create runner" i skopiuj token
RUNNER_TOKEN="<tutaj_wpisz_token>"

# Adres URL instancji GitLab — musi zawierać https:// i kończyć się ukośnikiem /
# Musi być identyczny jak GITLAB_DOMAIN użyty w skrypcie install_gitlabsrv.sh
GITLAB_URL="https://gitlab.example.com/"

# Domyślny obraz Docker używany w pipeline'ach (z hub.docker.com)
# Można go nadpisać w definicji pipeline'u (image: ...)
DOCKER_IMAGE="alpine:latest"

# Katalog główny GitLab — musi być identyczny jak GITLAB_DIR w install_gitlabsrv.sh
GITLAB_DIR="/gitlabsrv"





###############################################################################
# KONIEC SEKCJI KONFIGURACJI - nie modyfikuj poniżej tej linii
###############################################################################

# ---------------------------------------------------------------------------
# Kolory i funkcje pomocnicze
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }
step() {
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  $*${NC}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────┘${NC}"
}

# ---------------------------------------------------------------------------
# Sprawdzenie uprawnień root
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Skrypt wymaga uprawnień root. Użyj: sudo bash $0"

# ---------------------------------------------------------------------------
# Weryfikacja zmiennych konfiguracyjnych
# ---------------------------------------------------------------------------
[[ -z "$RUNNER_TOKEN" || "$RUNNER_TOKEN" == "<tutaj_wpisz_token>" ]] \
    && die "Zmienna RUNNER_TOKEN nie została uzupełniona. Wypełnij sekcję konfiguracji."
[[ -z "$GITLAB_URL" ]]   && die "Zmienna GITLAB_URL jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$DOCKER_IMAGE" ]] && die "Zmienna DOCKER_IMAGE jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$GITLAB_DIR" ]]   && die "Zmienna GITLAB_DIR jest pusta. Uzupełnij sekcję konfiguracji."

RUNNER_CONFIG_DIR="${GITLAB_DIR}/runner-config"
RUNNER_CONFIG_FILE="${RUNNER_CONFIG_DIR}/config.toml"
SELF_SIGNED_CERT="${GITLAB_DIR}/config/ssl/certwild.pem"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Rejestracja agenta GitLab Runner                 ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  URL GitLab   : ${YELLOW}${GITLAB_URL}${NC}"
echo -e "${GREEN}║${NC}  Obraz Docker : ${YELLOW}${DOCKER_IMAGE}${NC}"
echo -e "${GREEN}║${NC}  Katalog      : ${YELLOW}${RUNNER_CONFIG_DIR}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

###############################################################################
# KROK 1: Sprawdzenie stanu kontenera gitlab-runner
###############################################################################
step "KROK 1: Sprawdzenie stanu kontenera gitlab-runner"

if docker ps --format '{{.Names}}' | grep -q "^gitlab-runner$"; then
    ok "Kontener 'gitlab-runner' jest uruchomiony"
elif docker ps -a --format '{{.Names}}' | grep -q "^gitlab-runner$"; then
    info "Kontener 'gitlab-runner' istnieje, ale jest zatrzymany — uruchamianie..."
    docker start gitlab-runner
    sleep 3
    docker ps --format '{{.Names}}' | grep -q "^gitlab-runner$" \
        || die "Nie udało się uruchomić kontenera 'gitlab-runner'."
    ok "Kontener 'gitlab-runner' uruchomiony"
else
    die "Kontener 'gitlab-runner' nie istnieje.\nUruchom najpierw skrypt install_gitlabsrv.sh."
fi

###############################################################################
# KROK 2: Certyfikat SSL dla połączenia runner ↔ GitLab
###############################################################################
step "KROK 2: Certyfikat SSL dla połączenia runner ↔ GitLab"

# Tablica argumentów TLS — wypełniana warunkowo tylko dla certyfikatu samopodpisanego
TLS_ARGS=()

if [[ -f "$SELF_SIGNED_CERT" ]]; then
    DEST_CERT="${RUNNER_CONFIG_DIR}/certwild.pem"
    if [[ -f "$DEST_CERT" ]]; then
        ok "Certyfikat samopodpisany już skopiowany: ${DEST_CERT}"
    else
        info "Kopiowanie certyfikatu samopodpisanego do katalogu runner-config..."
        cp "$SELF_SIGNED_CERT" "$DEST_CERT"
        ok "Certyfikat skopiowany: ${DEST_CERT}"
    fi
    # Ścieżka wewnątrz kontenera (wolumen ./runner-config → /etc/gitlab-runner)
    TLS_ARGS=("--tls-ca-file" "/etc/gitlab-runner/certwild.pem")
    ok "Runner użyje certyfikatu samopodpisanego (--tls-ca-file)"
else
    ok "Brak certyfikatu samopodpisanego — zakładam Let's Encrypt lub publiczny CA"
fi

###############################################################################
# KROK 3: Rejestracja runnera w instancji GitLab
###############################################################################
step "KROK 3: Rejestracja runnera w instancji GitLab"

if [[ -f "$RUNNER_CONFIG_FILE" ]] && grep -q '^\[\[runners\]\]' "$RUNNER_CONFIG_FILE"; then
    ok "Runner jest już zarejestrowany — config.toml zawiera sekcję [[runners]]"
    warn "Aby zarejestrować ponownie, usuń wpis [[runners]] z: ${RUNNER_CONFIG_FILE}"
else
    info "Rejestrowanie runnera pod adresem: ${GITLAB_URL}..."

    docker exec gitlab-runner gitlab-runner register \
        --non-interactive \
        --url "${GITLAB_URL}" \
        --token "${RUNNER_TOKEN}" \
        "${TLS_ARGS[@]}" \
        --executor "docker" \
        --docker-image "${DOCKER_IMAGE}" \
        --description "docker-runner"

    # Weryfikacja — config.toml musi zawierać sekcję [[runners]]
    [[ -f "$RUNNER_CONFIG_FILE" ]] && grep -q '^\[\[runners\]\]' "$RUNNER_CONFIG_FILE" \
        || die "Rejestracja nie powiodła się — brak sekcji [[runners]] w config.toml."

    ok "Runner zarejestrowany pomyślnie"
fi

###############################################################################
# KROK 4: Konfiguracja Docker-in-Docker (privileged + docker.sock)
###############################################################################
step "KROK 4: Konfiguracja Docker-in-Docker w config.toml"

# --- privileged = true ---
# Wymagane aby runner mógł wykonywać polecenie docker build wewnątrz pipeline'ów
if grep -q "privileged = true" "$RUNNER_CONFIG_FILE"; then
    ok "Parametr 'privileged = true' już ustawiony"
else
    sed -i 's/privileged = false/privileged = true/' "$RUNNER_CONFIG_FILE"
    grep -q "privileged = true" "$RUNNER_CONFIG_FILE" \
        || die "Nie udało się ustawić 'privileged = true' w config.toml."
    ok "Ustawiono 'privileged = true'"
fi

# --- volumes z Docker socket ---
# Montowanie /var/run/docker.sock umożliwia uruchamianie kontenerów w pipeline'ach
if grep -q '/var/run/docker.sock:/var/run/docker.sock' "$RUNNER_CONFIG_FILE"; then
    ok "Wolumen /var/run/docker.sock już skonfigurowany"
else
    sed -i 's|volumes = \["/cache"\]|volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]|' \
        "$RUNNER_CONFIG_FILE"
    grep -q '/var/run/docker.sock:/var/run/docker.sock' "$RUNNER_CONFIG_FILE" \
        || die "Nie udało się zaktualizować sekcji 'volumes' w config.toml."
    ok "Zaktualizowano volumes: [\"/var/run/docker.sock:/var/run/docker.sock\", \"/cache\"]"
fi

# Restart runnera aby wczytał zaktualizowaną konfigurację
info "Restartowanie kontenera gitlab-runner (zastosowanie zmian w config.toml)..."
docker restart gitlab-runner
sleep 3

docker ps --format '{{.Names}}' | grep -q "^gitlab-runner$" \
    || die "Kontener 'gitlab-runner' nie uruchomił się po restarcie!"
ok "Kontener 'gitlab-runner' działa po restarcie"

###############################################################################
# PODSUMOWANIE
###############################################################################
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         REJESTRACJA RUNNERA ZAKOŃCZONA POMYŚLNIE             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Status runnera możesz zobaczyć w interfejsie GitLab:"
echo -e "${GREEN}║${NC}  ${BLUE}${GITLAB_URL}admin/runners${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Logi kontenera runnera:"
echo -e "${GREEN}║${NC}  ${BLUE}docker logs -f gitlab-runner${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
