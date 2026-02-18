#!/bin/bash
set -euo pipefail

###############################################################################
# SEKCJA KONFIGURACJI - DOSTOSUJ DO SWOICH POTRZEB
###############################################################################

# Katalog główny GitLab — musi być identyczny jak GITLAB_DIR w install_gitlabsrv.sh
GITLAB_DIR="/gitlabsrv"

# Maksymalny czas oczekiwania na zdrowy stan GitLab po aktualizacji (w sekundach)
# Dla dużych aktualizacji (migracje bazy danych) może być potrzebne więcej czasu
# Minimalna zalecana wartość: 300 (5 min), dla major upgrade: 600-900
HEALTH_TIMEOUT=600

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
err()  { echo -e "${RED}[ERR]${NC}   $*" >&2; }
die()  { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }
step() {
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  $*${NC}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────┘${NC}"
}

# ---------------------------------------------------------------------------
# Funkcja rollback — przywraca stare obrazy i restartuje kontenery
# ---------------------------------------------------------------------------
do_rollback() {
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ROLLBACK — przywracanie poprzedniej wersji            ${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    cd "${GITLAB_DIR}"

    info "Zatrzymywanie kontenerów z nowym obrazem..."
    docker compose down

    # Przywróć stary obraz GitLab przez ponowne otagowanie
    if [[ -n "${OLD_GITLAB_IMAGE:-}" ]]; then
        if docker image inspect "${OLD_GITLAB_IMAGE}" &>/dev/null 2>&1; then
            docker tag "${OLD_GITLAB_IMAGE}" gitlab/gitlab-ce:latest
            ok "Obraz GitLab przywrócony (SHA: ${OLD_GITLAB_IMAGE:7:16}...)"
        else
            err "Stary obraz GitLab (${OLD_GITLAB_IMAGE:7:16}...) niedostępny lokalnie — rollback niemożliwy!"
            return 1
        fi
    else
        warn "Brak zapisanego SHA starego obrazu GitLab — pomijam retag"
    fi

    # Przywróć stary obraz Runner
    if [[ -n "${OLD_RUNNER_IMAGE:-}" ]]; then
        if docker image inspect "${OLD_RUNNER_IMAGE}" &>/dev/null 2>&1; then
            docker tag "${OLD_RUNNER_IMAGE}" gitlab/gitlab-runner:latest
            ok "Obraz Runner przywrócony (SHA: ${OLD_RUNNER_IMAGE:7:16}...)"
        else
            warn "Stary obraz Runner niedostępny — runner zostanie uruchomiony z nowym obrazem"
        fi
    fi

    info "Uruchamianie kontenerów ze starą wersją..."
    docker compose up -d --force-recreate
    sleep 5

    if docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
        ok "Kontener GitLab uruchomiony po rollbacku"
    else
        err "Rollback nie powiódł się! Sprawdź logi: docker compose logs gitlab"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Sprawdzenie uprawnień root
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Skrypt wymaga uprawnień root. Użyj: sudo bash $0"

# ---------------------------------------------------------------------------
# Weryfikacja zmiennych konfiguracyjnych
# ---------------------------------------------------------------------------
[[ -z "$GITLAB_DIR" ]] && die "Zmienna GITLAB_DIR jest pusta. Uzupełnij sekcję konfiguracji."

COMPOSE_FILE="${GITLAB_DIR}/docker-compose.yml"

[[ -d "$GITLAB_DIR" ]] \
    || die "Katalog ${GITLAB_DIR} nie istnieje. Sprawdź zmienną GITLAB_DIR."
[[ -f "$COMPOSE_FILE" ]] \
    || die "Plik ${COMPOSE_FILE} nie istnieje. Sprawdź czy instalacja została przeprowadzona."

# ---------------------------------------------------------------------------
# Odczytaj aktualną wersję GitLab przed aktualizacją
# ---------------------------------------------------------------------------
VERSION_BEFORE=""
if docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
    VERSION_BEFORE=$(docker exec gitlab \
        cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo "nieznana")
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Aktualizacja serwera GitLab CE                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Katalog          : ${YELLOW}${GITLAB_DIR}${NC}"
echo -e "${GREEN}║${NC}  Wersja przed     : ${YELLOW}${VERSION_BEFORE:-kontener nie działa}${NC}"
echo -e "${GREEN}║${NC}  Limit zdrowia    : ${YELLOW}${HEALTH_TIMEOUT}s ($((HEALTH_TIMEOUT/60)) min)${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

###############################################################################
# KROK 1: Weryfikacja stanu kontenerów + zapis SHA starych obrazów
###############################################################################
step "KROK 1: Weryfikacja stanu kontenerów i zapis bieżących obrazów"

OLD_GITLAB_IMAGE=""
OLD_RUNNER_IMAGE=""

if docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
    OLD_GITLAB_IMAGE=$(docker inspect gitlab --format='{{.Image}}' 2>/dev/null || echo "")
    ok "Kontener 'gitlab' działa | SHA obrazu: ${OLD_GITLAB_IMAGE:7:16}..."
else
    warn "Kontener 'gitlab' nie jest uruchomiony — rollback do obrazu może nie być możliwy"
fi

if docker ps --format '{{.Names}}' | grep -q "^gitlab-runner$"; then
    OLD_RUNNER_IMAGE=$(docker inspect gitlab-runner --format='{{.Image}}' 2>/dev/null || echo "")
    ok "Kontener 'gitlab-runner' działa | SHA obrazu: ${OLD_RUNNER_IMAGE:7:16}..."
else
    warn "Kontener 'gitlab-runner' nie jest uruchomiony"
fi

###############################################################################
# KROK 2: Pobranie najnowszych obrazów Docker
###############################################################################
step "KROK 2: Pobieranie najnowszych obrazów Docker"

cd "${GITLAB_DIR}"

info "Pobieranie najnowszych obrazów (docker compose pull)..."
docker compose pull

ok "Obrazy pobrane pomyślnie"

###############################################################################
# KROK 3: Restart kontenerów z nowymi obrazami
###############################################################################
step "KROK 3: Restart kontenerów z nowymi obrazami"

info "Uruchamianie kontenerów z nowymi obrazami (--force-recreate)..."
docker compose up -d --force-recreate

sleep 5

if ! docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
    err "Kontener 'gitlab' nie uruchomił się po recreate — inicjowanie rollback..."
    do_rollback && warn "Rollback zakończony. Skrypt przerwany." && exit 1
    die "Rollback również nie powiódł się. Wymagana ręczna interwencja."
fi

ok "Kontener 'gitlab' uruchomiony (czekam na zdrowy stan usług wewnątrz...)"

if docker ps --format '{{.Names}}' | grep -q "^gitlab-runner$"; then
    ok "Kontener 'gitlab-runner' uruchomiony"
else
    warn "Kontener 'gitlab-runner' nie uruchomił się — sprawdź: docker logs gitlab-runner"
fi

###############################################################################
# KROK 4: Weryfikacja zdrowia GitLab + automatyczny rollback
###############################################################################
step "KROK 4: Weryfikacja zdrowia GitLab (maks. $((HEALTH_TIMEOUT/60)) min)"

info "Polling gitlab-ctl status co 15 sekund..."
info "GitLab musi uruchomić wszystkie usługi wewnętrzne (puma, sidekiq, nginx, itd.)"
info "Podczas upgrade'u mogą trwać migracje bazy danych — to normalne."
echo ""

HEALTH_OK=false
HEALTH_ELAPSED=0
HEALTH_INTERVAL=15

while [[ $HEALTH_ELAPSED -lt $HEALTH_TIMEOUT ]]; do

    # Sprawdź najpierw czy kontener nadal działa
    if ! docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
        err "Kontener 'gitlab' zatrzymał się nieoczekiwanie!"
        break
    fi

    # gitlab-ctl status zwraca 0 gdy WSZYSTKIE usługi działają
    if docker exec gitlab gitlab-ctl status >/dev/null 2>&1; then
        HEALTH_OK=true
        ok "GitLab zdrowy — wszystkie usługi wewnętrzne uruchomione! (${HEALTH_ELAPSED}s)"
        break
    fi

    sleep $HEALTH_INTERVAL
    HEALTH_ELAPSED=$((HEALTH_ELAPSED + HEALTH_INTERVAL))
    info "Inicjalizacja trwa... (${HEALTH_ELAPSED}/${HEALTH_TIMEOUT}s)"
done

# ---------------------------------------------------------------------------
# Rollback jeśli health check nie przeszedł
# ---------------------------------------------------------------------------
if [[ "$HEALTH_OK" == "false" ]]; then
    echo ""
    err "GitLab nie osiągnął zdrowego stanu w ciągu $((HEALTH_TIMEOUT/60)) minut!"
    err "Ostatni status usług wewnętrznych:"
    docker exec gitlab gitlab-ctl status 2>/dev/null || true
    echo ""
    warn "Inicjowanie automatycznego rollbacku..."
    echo ""

    if do_rollback; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║              ROLLBACK ZAKOŃCZONY POMYŚLNIE                   ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  Przywrócono wersję: ${VERSION_BEFORE:-nieznana}"
        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  GitLab działa na poprzednim obrazie."
        echo -e "${YELLOW}║${NC}  Sprawdź logi nowej wersji przed kolejną próbą upgrade:"
        echo -e "${YELLOW}║${NC}  ${BLUE}cd ${GITLAB_DIR} && docker compose logs gitlab${NC}"
        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
    else
        die "Rollback nie powiódł się. Wymagana ręczna interwencja!"
    fi
    exit 1
fi

###############################################################################
# KROK 5: Odczyt wersji GitLab po aktualizacji
###############################################################################
step "KROK 5: Odczyt wersji GitLab po aktualizacji"

VERSION_AFTER=$(docker exec gitlab \
    cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo "")

if [[ -n "$VERSION_AFTER" ]]; then
    ok "Wersja GitLab po aktualizacji: ${VERSION_AFTER}"
    if [[ -n "$VERSION_BEFORE" && "$VERSION_BEFORE" != "$VERSION_AFTER" ]]; then
        ok "Zaktualizowano: ${VERSION_BEFORE} → ${VERSION_AFTER}"
    elif [[ -n "$VERSION_BEFORE" && "$VERSION_BEFORE" == "$VERSION_AFTER" ]]; then
        info "Wersja nie zmieniła się (${VERSION_AFTER}) — obraz był już aktualny"
    fi
else
    warn "Nie udało się odczytać wersji z kontenera"
    VERSION_AFTER="nieznana"
fi

###############################################################################
# PODSUMOWANIE
###############################################################################
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         AKTUALIZACJA GITLAB ZAKOŃCZONA POMYŚLNIE             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}Wersja przed:${NC}  ${VERSION_BEFORE:-nieznana}"
echo -e "${GREEN}║${NC}  ${YELLOW}Wersja po:${NC}     ${VERSION_AFTER}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}UWAGA:${NC} Jeśli GitLab nie odpowiada w przeglądarce,"
echo -e "${GREEN}║${NC}  odczekaj kilka minut."
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Śledzenie logów GitLab:"
echo -e "${GREEN}║${NC}  ${BLUE}cd ${GITLAB_DIR} && docker compose logs -f gitlab${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Status kontenerów:"
echo -e "${GREEN}║${NC}  ${BLUE}cd ${GITLAB_DIR} && docker compose ps${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
