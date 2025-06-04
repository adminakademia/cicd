#!/bin/bash

# Ponizej wpisz nazwe swojego konta dockerhub:
konto_docker_hub="adminakademia"


###########################################################
# Klonowanie repozytorium Git
REPO_URL="https://github.com/adminakademia/dockerdns.git"
REPO_NAME="dockerdns"

if [ -d "$REPO_NAME" ]; then
    echo "Katalog $REPO_NAME już istnieje. Usuwam..."
    rm -rf "$REPO_NAME"
fi

echo "Klonowanie repozytorium $REPO_URL..."
git clone "$REPO_URL"

# Przejście do katalogu z repozytorium
cd "$REPO_NAME" || { echo "Nie udało się wejść do katalogu $REPO_NAME"; exit 1; }

# Budowanie obrazu Docker
echo "Budowanie obrazu Docker: moj-server-dns"
docker build -t moj-server-dns .

# Wysyłanie obrazu do Docker Hub
echo "Logowanie do Docker Hub..."
docker login -u $konto_docker_hub || { echo "Logowanie nie powiodło się"; exit 1; }

echo "Tagowanie obrazu..."
docker tag moj-server-dns:latest $konto_docker_hub/moj-server-dns:latest

echo "Wysyłanie obrazu do Docker Hub..."
docker push $konto_docker_hub/moj-server-dns:latest

echo "Zakończono."
