#!/bin/bash
set -euo pipefail

###############################################################################
# SEKCJA KONFIGURACJI - DOSTOSUJ SKRYPT DO SWOICH POTRZEB
###############################################################################

# Podaj domenę DNS dla instancji serwera GitLab
# Przykład: gitlab.example.com lub adres IP serwera
GITLAB_DOMAIN="gitlab.example.com"

# Nowy port SSH systemu hosta (na potrzeby zwolnienia portu 22 dla GitLab)
# Po tej zmianie połączenia SSH do serwera należy wykonywać: ssh -p ${SSH_NEW_PORT} user@host
# GitLab przejmie port 22 dla operacji git clone / push / pull
SSH_NEW_PORT=2222

# Podaj ścieżkę katalogu głównego dla danych serwera GitLab (konfiguracja, logi, dane)
GITLAB_DIR="/gitlabsrv"

# ---------------------------------------------------------------------------
# Wybierz tryb SSL/HTTPS
# "selfsigned"  — certyfikat samopodpisany (wildcard); nie wymaga publicznego DNS
# "letsencrypt" — certyfikat Let's Encrypt; wymaga publicznie dostępnej domeny
#                 oraz otwartego portu 80 (challenge ACME HTTP-01)
# ---------------------------------------------------------------------------
SSL_MODE="selfsigned"

# ---------------------------------------------------------------------------
# Ustawienia certyfikatu SAMOPODPISANEGO (aktywne gdy SSL_MODE="selfsigned")
# CN i SAN zostaną automatycznie wyprowadzone z GITLAB_DOMAIN
# np. dla gitlab.example.com certyfikat będzie wystawiony dla *.example.com
# ---------------------------------------------------------------------------
SSL_STATE="SLASK"                    # Województwo            (ST=)
SSL_CITY="Gliwice"                   # Miejscowość            (L=)
SSL_ORG="Contoso"                    # Nazwa organizacji      (O=)
SSL_EMAIL="kontakt@example.com"      # Adres e-mail w certyfikacie

# ---------------------------------------------------------------------------
# Ustawienia LET'S ENCRYPT (aktywne gdy SSL_MODE="letsencrypt")
# WYMAGANIE: domena GITLAB_DOMAIN musi być publiczna (DNS + port 80 otwarty)
# ---------------------------------------------------------------------------
LE_EMAIL="admin@example.com"         # E-mail do powiadomień o wygasaniu certyfikatu

# ---------------------------------------------------------------------------
# Konfiguracja SMTP — wysyłanie e-maili przez konto Gmail
# Wymagane: włączone 2FA w Google + wygenerowane hasło do aplikacji
# Hasło do aplikacji nalezy uzyskać: https://myaccount.google.com/apppasswords
# ---------------------------------------------------------------------------
SMTP_USER="twoj.adres@gmail.com"          # Adres konta Gmail (login SMTP)
SMTP_PASSWORD="twojehasloaplikacji"        # 16-znakowe hasło do aplikacji Google (bez spacji)
EMAIL_FROM="twoj.adres@gmail.com"          # Adres nadawcy (musi być zgodny z SMTP_USER)
EMAIL_DISPLAY_NAME="GitLab Mojadomena"     # Wyświetlana nazwa nadawcy w e-mailach
EMAIL_REPLY_TO="twoj.adres@gmail.com"      # Adres do odpowiedzi






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
[[ -z "$GITLAB_DOMAIN" ]]  && die "Zmienna GITLAB_DOMAIN jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$SSH_NEW_PORT" ]]   && die "Zmienna SSH_NEW_PORT jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$GITLAB_DIR" ]]     && die "Zmienna GITLAB_DIR jest pusta. Uzupełnij sekcję konfiguracji."
[[ "$SSH_NEW_PORT" -eq 22 ]] && die "SSH_NEW_PORT nie może być równy 22 (ten port jest zarezerwowany dla GitLab)."

if [[ "$SSL_MODE" != "selfsigned" && "$SSL_MODE" != "letsencrypt" ]]; then
    die "SSL_MODE musi mieć wartość 'selfsigned' lub 'letsencrypt'. Uzupełnij sekcję konfiguracji."
fi

if [[ "$SSL_MODE" == "selfsigned" ]]; then
    [[ -z "$SSL_STATE" ]]  && die "Zmienna SSL_STATE jest pusta. Uzupełnij sekcję konfiguracji."
    [[ -z "$SSL_CITY" ]]   && die "Zmienna SSL_CITY jest pusta. Uzupełnij sekcję konfiguracji."
    [[ -z "$SSL_ORG" ]]    && die "Zmienna SSL_ORG jest pusta. Uzupełnij sekcję konfiguracji."
    [[ -z "$SSL_EMAIL" ]]  && die "Zmienna SSL_EMAIL jest pusta. Uzupełnij sekcję konfiguracji."
fi

if [[ "$SSL_MODE" == "letsencrypt" ]]; then
    [[ -z "$LE_EMAIL" ]] && die "Zmienna LE_EMAIL jest pusta. Uzupełnij sekcję konfiguracji."
fi

[[ -z "$SMTP_USER" ]]         && die "Zmienna SMTP_USER jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$SMTP_PASSWORD" ]]     && die "Zmienna SMTP_PASSWORD jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$EMAIL_FROM" ]]        && die "Zmienna EMAIL_FROM jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$EMAIL_DISPLAY_NAME" ]] && die "Zmienna EMAIL_DISPLAY_NAME jest pusta. Uzupełnij sekcję konfiguracji."
[[ -z "$EMAIL_REPLY_TO" ]]    && die "Zmienna EMAIL_REPLY_TO jest pusta. Uzupełnij sekcję konfiguracji."

# Wyprowadź domenę główną z GITLAB_DOMAIN (np. gitlab.example.com → example.com)
# Używana jako baza dla certyfikatu wildcard *.domena.pl
SSL_ROOT_DOMAIN="${GITLAB_DOMAIN#*.}"
if [[ "$SSL_MODE" == "selfsigned" && "$SSL_ROOT_DOMAIN" == "$GITLAB_DOMAIN" ]]; then
    warn "GITLAB_DOMAIN ('${GITLAB_DOMAIN}') nie zawiera subdomeny."
    warn "Certyfikat wildcard zostanie wystawiony dla: *.${SSL_ROOT_DOMAIN}"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Instalacja samodzielnego serwera GitLab CE           ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Domena GitLab  : ${YELLOW}https://${GITLAB_DOMAIN}${NC}"
echo -e "${GREEN}║${NC}  Port SSH hosta : ${YELLOW}${SSH_NEW_PORT}${NC} (port 22 zostanie przekazany GitLab)"
echo -e "${GREEN}║${NC}  Katalog danych : ${YELLOW}${GITLAB_DIR}${NC}"
if [[ "$SSL_MODE" == "selfsigned" ]]; then
    echo -e "${GREEN}║${NC}  Certyfikat SSL : ${YELLOW}Samopodpisany wildcard *.${SSL_ROOT_DOMAIN}${NC}"
else
    echo -e "${GREEN}║${NC}  Certyfikat SSL : ${YELLOW}Let's Encrypt${NC} (kontakt: ${LE_EMAIL})"
fi
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

###############################################################################
# KROK 1: Aktualizacja systemu i instalacja pakietów bazowych
###############################################################################
step "KROK 1: Aktualizacja systemu i instalacja pakietów"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

PACKAGES=(mc sudo curl htop cron ca-certificates ufw openssl)
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' || MISSING+=("$pkg")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "Wszystkie wymagane pakiety są już zainstalowane"
else
    info "Instalacja brakujących pakietów: ${MISSING[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
    ok "Pakiety zainstalowane: ${MISSING[*]}"
fi

###############################################################################
# KROK 2: Konfiguracja zapory UFW
###############################################################################
step "KROK 2: Konfiguracja zapory UFW"

info "Dodawanie reguł zapory..."
# ufw allow jest idempotentne — pomija reguły, które już istnieją
ufw allow "${SSH_NEW_PORT}/tcp" > /dev/null
ok "Reguła UFW: ${SSH_NEW_PORT}/tcp (SSH systemu hosta)"

ufw allow 80/tcp > /dev/null
ok "Reguła UFW: 80/tcp (HTTP — przekierowanie na HTTPS)"

ufw allow 443/tcp > /dev/null
ok "Reguła UFW: 443/tcp (HTTPS)"

ufw allow 22/tcp > /dev/null
ok "Reguła UFW: 22/tcp (SSH GitLab)"

if ufw status | grep -q "Status: active"; then
    ok "Zapora UFW jest już aktywna"
else
    info "Włączanie zapory UFW..."
    echo "y" | ufw enable > /dev/null
    ok "Zapora UFW włączona"
fi

ufw status verbose

###############################################################################
# KROK 3: Zmiana portu SSH systemu hosta
###############################################################################
step "KROK 3: Zmiana portu SSH systemu hosta na ${SSH_NEW_PORT}"

SSHD_CONFIG="/etc/ssh/sshd_config"

if grep -qE "^Port ${SSH_NEW_PORT}$" "$SSHD_CONFIG"; then
    ok "Port SSH systemu jest już ustawiony na ${SSH_NEW_PORT} — pomijam"
else
    if grep -qE "^#?Port [0-9]+" "$SSHD_CONFIG"; then
        # Zamień istniejącą (aktywną lub zakomentowaną) linię Port
        sed -i -E "s/^#?Port [0-9]+/Port ${SSH_NEW_PORT}/" "$SSHD_CONFIG"
    else
        # Brak linii Port w pliku — dodaj na początku
        sed -i "1i Port ${SSH_NEW_PORT}" "$SSHD_CONFIG"
    fi

    # Weryfikacja zmiany
    grep -qE "^Port ${SSH_NEW_PORT}$" "$SSHD_CONFIG" \
        || die "Nie udało się ustawić portu SSH na ${SSH_NEW_PORT} w ${SSHD_CONFIG}"

    info "Restartowanie usługi SSH..."
    systemctl restart ssh
    ok "Port SSH systemu zmieniony na ${SSH_NEW_PORT}, usługa zrestartowana"
    warn "WAŻNE: Nowe połączenia SSH do serwera wymagają teraz: ssh -p ${SSH_NEW_PORT} user@host"
fi

###############################################################################
# KROK 4: Instalacja Docker
###############################################################################
step "KROK 4: Instalacja Docker CE"

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    ok "Docker jest już zainstalowany: $(docker --version)"
else
    info "Instalacja Docker z oficjalnego repozytorium..."

    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        ok "Klucz GPG Docker pobrany"
    else
        ok "Klucz GPG Docker już istnieje"
    fi

    if [[ ! -f /etc/apt/sources.list.d/docker.sources ]]; then
        # Wczytaj zmienne systemu operacyjnego (m.in. VERSION_CODENAME)
        # shellcheck disable=SC1091
        . /etc/os-release
        cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        ok "Repozytorium Docker skonfigurowane dla Debian ${VERSION_CODENAME}"
    else
        ok "Repozytorium Docker już skonfigurowane"
    fi

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    docker info &>/dev/null 2>&1 \
        || die "Instalacja Docker nie powiodła się. Sprawdź logi: journalctl -u docker"

    ok "Docker zainstalowany: $(docker --version)"
fi

###############################################################################
# KROK 5: Tworzenie struktury katalogów GitLab
###############################################################################
step "KROK 5: Tworzenie struktury katalogów w ${GITLAB_DIR}"

mkdir -p "${GITLAB_DIR}"/{config,data,logs,runner-config}
ok "Katalogi gotowe:"
ok "  ${GITLAB_DIR}/config         — konfiguracja GitLab"
ok "  ${GITLAB_DIR}/logs           — logi GitLab"
ok "  ${GITLAB_DIR}/data           — dane aplikacji GitLab"
ok "  ${GITLAB_DIR}/runner-config  — konfiguracja GitLab Runner"

###############################################################################
# KROK 6: Certyfikat SSL
###############################################################################

if [[ "$SSL_MODE" == "selfsigned" ]]; then

    step "KROK 6: Generowanie certyfikatu SSL samopodpisanego"

    SSL_DIR="${GITLAB_DIR}/config/ssl"
    SSL_KEY="${SSL_DIR}/certwild.key"
    SSL_CERT="${SSL_DIR}/certwild.pem"

    mkdir -p "$SSL_DIR"

    if [[ -f "$SSL_KEY" && -f "$SSL_CERT" ]]; then
        ok "Certyfikat SSL już istnieje — pomijam generowanie"
        ok "  Klucz:      ${SSL_KEY}"
        ok "  Certyfikat: ${SSL_CERT}"
        CERT_EXPIRY=$(openssl x509 -noout -enddate -in "$SSL_CERT" 2>/dev/null \
            | cut -d= -f2 || echo "nie udało się odczytać")
        ok "  Ważny do:   ${CERT_EXPIRY}"
    else
        info "Generowanie certyfikatu SSL wildcard dla *.${SSL_ROOT_DOMAIN}..."
        openssl req -new -days 36500 -nodes -x509 \
            -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -subj "/C=PL/ST=${SSL_STATE}/L=${SSL_CITY}/O=${SSL_ORG}/OU=IT/CN=*.${SSL_ROOT_DOMAIN}/emailAddress=${SSL_EMAIL}" \
            -keyout "${SSL_KEY}" \
            -out "${SSL_CERT}" \
            -addext "subjectAltName=DNS:${SSL_ROOT_DOMAIN},DNS:*.${SSL_ROOT_DOMAIN}" \
            2>/dev/null

        # Weryfikacja wygenerowanych plików
        [[ -f "$SSL_KEY" && -s "$SSL_KEY" ]]   || die "Nie udało się wygenerować klucza prywatnego SSL."
        [[ -f "$SSL_CERT" && -s "$SSL_CERT" ]] || die "Nie udało się wygenerować certyfikatu SSL."

        # Bezpieczne uprawnienia: klucz prywatny tylko dla root
        chmod 600 "${SSL_KEY}"
        chmod 644 "${SSL_CERT}"

        CERT_EXPIRY=$(openssl x509 -noout -enddate -in "$SSL_CERT" 2>/dev/null \
            | cut -d= -f2 || echo "nie udało się odczytać")

        ok "Certyfikat SSL wygenerowany:"
        ok "  Klucz:      ${SSL_KEY}"
        ok "  Certyfikat: ${SSL_CERT}"
        ok "  CN/SAN:     *.${SSL_ROOT_DOMAIN} + ${SSL_ROOT_DOMAIN}"
        ok "  Ważny do:   ${CERT_EXPIRY}"
    fi

else

    step "KROK 6: Certyfikat SSL — Let's Encrypt (konfiguracja automatyczna)"

    info "Certyfikat Let's Encrypt zostanie wygenerowany automatycznie"
    info "przez GitLab podczas pierwszego uruchomienia kontenera."
    echo ""
    warn "WYMAGANIA dla Let's Encrypt:"
    warn "  • Domena ${GITLAB_DOMAIN} musi wskazywać na ten serwer (rekord DNS A)"
    warn "  • Port 80 serwera musi być publicznie dostępny z internetu"
    warn "    (challenge ACME HTTP-01 — GitLab używa go do weryfikacji domeny)"
    echo ""
    ok "Pomijam ręczne generowanie certyfikatu"

fi

###############################################################################
# KROK 7: Tworzenie pliku docker-compose.yml
###############################################################################
step "KROK 7: Tworzenie pliku docker-compose.yml"

COMPOSE_FILE="${GITLAB_DIR}/docker-compose.yml"

# Zawsze zapisujemy plik — docker compose up -d sam wykryje,
# czy kontener wymaga przebudowania/restartu ze względu na zmianę konfiguracji

if [[ "$SSL_MODE" == "selfsigned" ]]; then

    cat > "${COMPOSE_FILE}" <<EOF
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: always
    hostname: '${GITLAB_DOMAIN}'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${GITLAB_DOMAIN}'
        gitlab_rails['gitlab_shell_ssh_port'] = 22
        gitlab_rails['time_zone'] = 'Europe/Warsaw'
        prometheus_monitoring['enable'] = false
        puma['worker_processes'] = 2
        puma['min_threads'] = 1
        puma['max_threads'] = 4
        sidekiq['concurrency'] = 5
        registry['enable'] = false
        letsencrypt['enable'] = false
        nginx['redirect_http_to_https'] = true
        nginx['ssl_certificate'] = "/etc/gitlab/ssl/certwild.pem"
        nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/certwild.key"
        gitlab_rails['smtp_enable'] = true
        gitlab_rails['smtp_address'] = "smtp.gmail.com"
        gitlab_rails['smtp_port'] = 587
        gitlab_rails['smtp_user_name'] = "${SMTP_USER}"
        gitlab_rails['smtp_password'] = "${SMTP_PASSWORD}"
        gitlab_rails['smtp_domain'] = "smtp.gmail.com"
        gitlab_rails['smtp_authentication'] = "login"
        gitlab_rails['smtp_enable_starttls_auto'] = true
        gitlab_rails['smtp_tls'] = false
        gitlab_rails['smtp_openssl_verify_mode'] = 'peer'
        gitlab_rails['gitlab_email_from'] = '${EMAIL_FROM}'
        gitlab_rails['gitlab_email_display_name'] = '${EMAIL_DISPLAY_NAME}'
        gitlab_rails['gitlab_email_reply_to'] = '${EMAIL_REPLY_TO}'
    ports:
      - '80:80'
      - '443:443'
      - '22:22'
    volumes:
      - './config:/etc/gitlab'
      - './logs:/var/log/gitlab'
      - './data:/var/opt/gitlab'
    shm_size: '256m'

  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: always
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock'
      - './runner-config:/etc/gitlab-runner'
EOF

else

    cat > "${COMPOSE_FILE}" <<EOF
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: always
    hostname: '${GITLAB_DOMAIN}'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${GITLAB_DOMAIN}'
        gitlab_rails['gitlab_shell_ssh_port'] = 22
        gitlab_rails['time_zone'] = 'Europe/Warsaw'
        prometheus_monitoring['enable'] = false
        puma['worker_processes'] = 2
        puma['min_threads'] = 1
        puma['max_threads'] = 4
        sidekiq['concurrency'] = 5
        registry['enable'] = false
        letsencrypt['enable'] = true
        letsencrypt['contact_emails'] = ['${LE_EMAIL}']
        letsencrypt['auto_renew'] = true
        letsencrypt['auto_renew_hour'] = 12
        letsencrypt['auto_renew_minute'] = 30
        letsencrypt['auto_renew_day_of_month'] = "*/7"
        nginx['redirect_http_to_https'] = true
        gitlab_rails['smtp_enable'] = true
        gitlab_rails['smtp_address'] = "smtp.gmail.com"
        gitlab_rails['smtp_port'] = 587
        gitlab_rails['smtp_user_name'] = "${SMTP_USER}"
        gitlab_rails['smtp_password'] = "${SMTP_PASSWORD}"
        gitlab_rails['smtp_domain'] = "smtp.gmail.com"
        gitlab_rails['smtp_authentication'] = "login"
        gitlab_rails['smtp_enable_starttls_auto'] = true
        gitlab_rails['smtp_tls'] = false
        gitlab_rails['smtp_openssl_verify_mode'] = 'peer'
        gitlab_rails['gitlab_email_from'] = '${EMAIL_FROM}'
        gitlab_rails['gitlab_email_display_name'] = '${EMAIL_DISPLAY_NAME}'
        gitlab_rails['gitlab_email_reply_to'] = '${EMAIL_REPLY_TO}'
    ports:
      - '80:80'
      - '443:443'
      - '22:22'
    volumes:
      - './config:/etc/gitlab'
      - './logs:/var/log/gitlab'
      - './data:/var/opt/gitlab'
    shm_size: '256m'

  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: always
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock'
      - './runner-config:/etc/gitlab-runner'
EOF

fi

ok "Plik ${COMPOSE_FILE} zapisany (tryb SSL: ${SSL_MODE})"

###############################################################################
# KROK 8: Uruchomienie kontenera GitLab
###############################################################################
step "KROK 8: Uruchomienie kontenera GitLab"

cd "${GITLAB_DIR}"

info "Uruchamianie docker compose up -d..."
docker compose up -d

# Krótkie oczekiwanie, aby Docker zdążył zarejestrować kontener
sleep 3

if docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
    ok "Kontener 'gitlab' jest uruchomiony"
else
    die "Kontener 'gitlab' nie uruchomił się poprawnie.\nSprawdź logi: cd ${GITLAB_DIR} && docker compose logs gitlab"
fi

###############################################################################
# KROK 9: Oczekiwanie na inicjalizację i odczyt hasła administratora
###############################################################################
step "KROK 9: Oczekiwanie na inicjalizację GitLab (do 10 minut)"

info "GitLab inicjalizuje konfigurację — to może potrwać od 3 do 10 minut..."
info "Możesz śledzić postęp w innym oknie terminala:"
info "  cd ${GITLAB_DIR} && docker compose logs -f gitlab"
echo ""

ROOT_PASSWORD=""
MAX_WAIT=600   # maksymalnie 600 sekund = 10 minut
INTERVAL=15    # sprawdzaj co 15 sekund
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    PASSWORD_LINE=$(docker exec gitlab \
        grep 'Password:' /etc/gitlab/initial_root_password 2>/dev/null || true)

    if [[ -n "$PASSWORD_LINE" ]]; then
        ROOT_PASSWORD=$(echo "$PASSWORD_LINE" | awk '{print $NF}')
        ok "Hasło administratora odczytane pomyślnie"
        break
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    info "Inicjalizacja trwa... (${ELAPSED}/${MAX_WAIT} s)"
done

if [[ -z "$ROOT_PASSWORD" ]]; then
    warn "Nie udało się automatycznie odczytać hasła w ciągu $((MAX_WAIT / 60)) minut."
    warn "GitLab może nadal się inicjalizować. Odczytaj hasło ręcznie:"
    warn "  sudo docker exec -it gitlab grep 'Password:' /etc/gitlab/initial_root_password"
    ROOT_PASSWORD="(odczytaj ręcznie — patrz komunikat powyżej)"
fi

###############################################################################
# PODSUMOWANIE
###############################################################################
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         INSTALACJA GITLAB ZAKOŃCZONA POMYŚLNIE               ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}Adres URL serwera GitLab:${NC}  https://${GITLAB_DOMAIN}"
echo -e "${GREEN}║${NC}  ${YELLOW}Login:${NC}                     root"
echo -e "${GREEN}║${NC}  ${YELLOW}Hasło root:${NC}                ${ROOT_PASSWORD}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
if [[ "$SSL_MODE" == "selfsigned" ]]; then
    echo -e "${GREEN}║${NC}  ${YELLOW}Certyfikat SSL:${NC}    Samopodpisany wildcard *.${SSL_ROOT_DOMAIN}"
    echo -e "${GREEN}║${NC}    Przeglądarka wyświetli ostrzeżenie o certyfikacie —"
    echo -e "${GREEN}║${NC}    jest to normalne dla certyfikatów samopodpisanych."
    echo -e "${GREEN}║${NC}    Pamiętaj o instalacji tego certyfikatu w kontenerze"
    echo -e "${GREEN}║${NC}    zaufanych głównych urzędów certyfikacji."
else
    echo -e "${GREEN}║${NC}  ${YELLOW}Certyfikat SSL:${NC}    Let's Encrypt (automatyczny)"
    echo -e "${GREEN}║${NC}    Certyfikat zostanie wygenerowany przez GitLab"
    echo -e "${GREEN}║${NC}    podczas pierwszego uruchomienia (wymaga publicznego DNS)."
    echo -e "${GREEN}║${NC}    Powiadomienia o wygasaniu: ${LE_EMAIL}"
    echo -e "${GREEN}║${NC}    Automatyczne odnawianie: co 7 dni o 12:30"
fi
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}Wykorzystywana poczta wychodząca (SMTP):${NC} Gmail / ${SMTP_USER}"
echo -e "${GREEN}║${NC}    Nadawca: ${EMAIL_DISPLAY_NAME} <${EMAIL_FROM}>"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}SSH systemu hosta:${NC} port ${SSH_NEW_PORT}"
echo -e "${GREEN}║${NC}    Połączenie: ssh -p ${SSH_NEW_PORT} user@${GITLAB_DOMAIN}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}Katalog danych:${NC}    ${GITLAB_DIR}/"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}UWAGA:${NC} Pierwsze uruchomienie GitLab może potrwać"
echo -e "${GREEN}║${NC}  od 3 do 10 minut. Jeśli strona nie odpowiada — odczekaj"
echo -e "${GREEN}║${NC}  chwilę i odśwież przeglądarkę."
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Śledzenie logów kontenera:"
echo -e "${GREEN}║${NC}  ${BLUE}cd ${GITLAB_DIR} && docker compose logs -f gitlab${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Ręczny odczyt hasła root (jeśli plik nadal istnieje):"
echo -e "${GREEN}║${NC}  ${BLUE}sudo docker exec -it gitlab grep 'Password:' \\${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}  /etc/gitlab/initial_root_password${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Pamiętaj o zarejestrowaniu agenta GitLab Runner w kontenerze 'gitlab-runner'.
echo -e "${GREEN}║${NC}  Wykorzystaj do tego celu skrypt rejestracyjny: register_runner.sh
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
