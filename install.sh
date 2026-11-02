#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# AI Starter voor macOS (werkt ook op Linux)
#
# Installeert zonder sudo:
#   Git (macOS: via de Command Line Tools van Apple), Node.js (LTS),
#   GitHub CLI (gh) en Firebase CLI
# in ~/.ai-starter en zet ze in je PATH (~/.zshrc).
#
# Gebruik in Terminal:   curl -fsSL https://fabianb88.github.io/ai-starter/install.sh | bash
# Verwijderen:           curl -fsSL https://fabianb88.github.io/ai-starter/install.sh | bash -s -- --verwijder
#
# Wat al op de computer staat wordt overgeslagen. Opnieuw draaien mag altijd.
# ---------------------------------------------------------------------------

set -u

ROOT="$HOME/.ai-starter"
TMP="$ROOT/_download"
UA="User-Agent: AI-Starter"
MARK="# AI Starter"
RCLINE='export PATH="$HOME/.ai-starter/node/bin:$HOME/.ai-starter/npm/bin:$HOME/.ai-starter/gh/bin:$PATH"'

C_M=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[90m'; C_0=$'\033[0m'
step() { printf '\n%s== %s%s\n' "$C_M" "$1" "$C_0"; }
ok()   { printf '   %sOK%s  %s\n' "$C_G" "$C_0" "$1"; }
info() { printf '   %s..  %s%s\n' "$C_D" "$1" "$C_0"; }
warn() { printf '   %s!!  %s%s\n' "$C_Y" "$1" "$C_0"; }

# Lezen van het toetsenbord werkt ook als het script via "curl ... | bash" draait.
ask() {
    local a=""
    if { true < /dev/tty; } 2>/dev/null; then read -r -p "   $1 " a < /dev/tty || a=""; fi
    printf '%s' "$a"
}

dl() { curl -fL --retry 3 --retry-delay 2 -sS -H "$UA" -o "$2" "$1"; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# check_sum <bestand> <naam-in-lijst> <url-van-lijst>
# Lijst niet op te halen: waarschuwen en doorgaan. Controlesom klopt niet: stoppen.
check_sum() {
    local want
    if ! dl "$3" "$TMP/sums.txt"; then warn "controlesom niet op te halen, ik ga door zonder controle"; return 0; fi
    want=$(awk -v f="$2" '{n=$2; sub(/^\*/,"",n)} n==f {print $1; exit}' "$TMP/sums.txt")
    if [ -z "$want" ]; then warn "geen controlesom gevonden voor $2, ik ga door zonder controle"; return 0; fi
    if [ "$(sha256 "$1")" != "$want" ]; then warn "controlesom klopt niet voor $2, probeer het opnieuw"; return 1; fi
    info "controlesom klopt"
}

# Volgt /releases/latest naar /releases/tag/<versie>; geen GitHub-API-limiet.
latest_tag() {
    curl -fsSL -H "$UA" -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" \
        | sed -n 's#.*/tag/\([^/?#]*\).*#\1#p'
}

# Op een Mac zonder Command Line Tools is /usr/bin/git alleen een doorverwijzing
# die bij elke aanroep het installatievenster opent; dan telt Git als afwezig.
has_git() {
    command -v git >/dev/null 2>&1 || return 1
    [ "$OS" != Darwin ] && return 0
    xcode-select -p >/dev/null 2>&1 || [ "$(command -v git)" != /usr/bin/git ]
}

add_path() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH"; export PATH ;; esac; }

rc_files() {
    if [ "$OS" = Darwin ]; then
        echo "$HOME/.zshrc"
        if [ -f "$HOME/.bash_profile" ]; then echo "$HOME/.bash_profile"; fi
    else
        echo "$HOME/.bashrc"
        if [ -f "$HOME/.zshrc" ]; then echo "$HOME/.zshrc"; fi
    fi
}

# ---------- platform ----------

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Darwin) NODE_OS=darwin; GH_OS=macOS; GH_EXT=zip ;;
    Linux)  NODE_OS=linux;  GH_OS=linux; GH_EXT=tar.gz ;;
    *) echo "Dit script is voor macOS en Linux. Gebruik op Windows install.ps1."; exit 1 ;;
esac
# Terminal onder Rosetta meldt x86_64 op een Apple Silicon-Mac; dan toch arm64 nemen.
if [ "$OS" = Darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then ARCH=arm64; fi
case "$ARCH" in
    arm64|aarch64) NODE_ARCH=arm64; GH_ARCH=arm64 ;;
    x86_64|amd64)  NODE_ARCH=x64;   GH_ARCH=amd64 ;;
    *) echo "Onbekend processortype: $ARCH"; exit 1 ;;
esac

# ---------- onderdelen ----------

install_git() {
    step "Git"
    if [ "$OS" = Darwin ]; then
        if xcode-select -p >/dev/null 2>&1; then ok "al aanwezig: $(git --version)"; return 0; fi
        if command -v git >/dev/null 2>&1 && [ "$(command -v git)" != /usr/bin/git ]; then
            ok "al aanwezig: $(git --version)"; return 0
        fi
        info "macOS opent nu een venster voor de Command Line Tools (daar zit Git in)."
        info "Klik op Installeer en wacht tot het klaar is; dit script wacht mee."
        xcode-select --install >/dev/null 2>&1 || true
        local waited=0
        until xcode-select -p >/dev/null 2>&1; do
            sleep 10; waited=$((waited + 10))
            if [ "$waited" -ge 1800 ]; then
                warn "Command Line Tools zijn na 30 minuten nog niet klaar. Draai dit script opnieuw als ze er zijn."
                return 1
            fi
        done
        ok "geinstalleerd: $(git --version)"
    else
        if command -v git >/dev/null 2>&1; then ok "al aanwezig: $(git --version)"; return 0; fi
        warn "Git ontbreekt. Op Linux gaat dat via je pakketbeheer, bijvoorbeeld: sudo apt install git"
        return 1
    fi
}

node_major() {
    command -v node >/dev/null 2>&1 || { echo 0; return; }
    local m; m=$(node -v 2>/dev/null | sed -n 's/^v\([0-9]*\)\..*/\1/p')
    echo "${m:-0}"
}

install_node() {
    step "Node.js"
    local m v name
    m=$(node_major)
    if [ "$m" -ge 20 ]; then ok "al aanwezig: node $(node -v)"; return 0; fi
    if [ "$m" -gt 0 ]; then warn "oude Node.js gevonden (v$m), ik zet een actuele LTS-versie ernaast"; fi

    # Nieuwste LTS uit de officiele index (nieuwste versies staan bovenaan).
    v=$(curl -fsSL -H "$UA" https://nodejs.org/dist/index.json \
        | tr '{' '\n' | grep -v '"lts": *false' | grep -o '"version": *"v[0-9.]*"' | head -n 1 | cut -d'"' -f4)
    if [ -z "$v" ]; then warn "kon de nieuwste LTS-versie van Node.js niet bepalen"; return 1; fi

    name="node-$v-$NODE_OS-$NODE_ARCH"
    info "downloaden: Node.js $v"
    dl "https://nodejs.org/dist/$v/$name.tar.gz" "$TMP/$name.tar.gz" || { warn "download van Node.js mislukt"; return 1; }
    check_sum "$TMP/$name.tar.gz" "$name.tar.gz" "https://nodejs.org/dist/$v/SHASUMS256.txt" || return 1

    rm -rf "${TMP:?}/$name" "$ROOT/node"
    if ! tar -xzf "$TMP/$name.tar.gz" -C "$TMP" || ! mv "$TMP/$name" "$ROOT/node"; then
        warn "uitpakken van Node.js mislukt"; return 1
    fi
    add_path "$ROOT/node/bin"
    ok "geinstalleerd: node $("$ROOT/node/bin/node" -v)"
}

install_gh() {
    step "GitHub CLI"
    if command -v gh >/dev/null 2>&1; then ok "al aanwezig: $(gh --version | head -n 1)"; return 0; fi
    local tag ver file base bin
    tag=$(latest_tag cli/cli)
    if [ -z "$tag" ]; then warn "kon de nieuwste versie van GitHub CLI niet bepalen"; return 1; fi
    ver=${tag#v}
    file="gh_${ver}_${GH_OS}_${GH_ARCH}.${GH_EXT}"
    base="https://github.com/cli/cli/releases/download/$tag"

    info "downloaden: GitHub CLI $ver"
    dl "$base/$file" "$TMP/$file" || { warn "download van GitHub CLI mislukt"; return 1; }
    check_sum "$TMP/$file" "$file" "$base/gh_${ver}_checksums.txt" || return 1

    rm -rf "${TMP:?}/gh-x" "$ROOT/gh"
    mkdir -p "$TMP/gh-x"
    if [ "$GH_EXT" = zip ]; then unzip -q "$TMP/$file" -d "$TMP/gh-x" || { warn "uitpakken mislukt"; return 1; }
    else tar -xzf "$TMP/$file" -C "$TMP/gh-x" || { warn "uitpakken mislukt"; return 1; }; fi
    bin=$(find "$TMP/gh-x" -type f -path '*/bin/gh' | head -n 1)
    if [ -z "$bin" ]; then warn "gh niet gevonden in de download"; return 1; fi

    mkdir -p "$ROOT/gh/bin"
    mv "$bin" "$ROOT/gh/bin/gh"
    chmod +x "$ROOT/gh/bin/gh"
    add_path "$ROOT/gh/bin"
    ok "geinstalleerd: $("$ROOT/gh/bin/gh" --version | head -n 1)"
}

install_firebase() {
    step "Firebase CLI"
    if command -v firebase >/dev/null 2>&1; then ok "al aanwezig: firebase $(firebase --version)"; return 0; fi
    if ! command -v npm >/dev/null 2>&1; then
        warn "npm niet gevonden, dus Firebase kan niet worden geinstalleerd (Node.js is niet gelukt)"; return 1
    fi
    mkdir -p "$ROOT/npm"
    info "installeren via npm (1 tot 3 minuten)"
    # --prefix houdt het in je eigen map, dus geen sudo, ook niet als Node.js elders staat.
    npm install -g firebase-tools --prefix "$ROOT/npm" --no-fund --no-audit --no-update-notifier --loglevel=error \
        || { warn "npm install firebase-tools is mislukt"; return 1; }
    add_path "$ROOT/npm/bin"
    ok "geinstalleerd: firebase $("$ROOT/npm/bin/firebase" --version)"
}

write_rc() {
    local rc
    while IFS= read -r rc; do
        touch "$rc"
        if ! grep -qF "$MARK" "$rc" 2>/dev/null; then printf '\n%s\n%s\n' "$MARK" "$RCLINE" >> "$rc"; fi
    done < <(rc_files)
}

set_identity() {
    has_git || return 0
    step "Git instellen"
    local name mail
    name=$(git config --global user.name 2>/dev/null)
    if [ -z "$name" ]; then
        name=$(ask "Je volledige naam voor Git (Enter = overslaan):")
        [ -n "$name" ] && git config --global user.name "$name"
    else ok "naam: $name"; fi
    mail=$(git config --global user.email 2>/dev/null)
    if [ -z "$mail" ]; then
        mail=$(ask "Je e-mailadres voor Git, liefst hetzelfde als op GitHub (Enter = overslaan):")
        [ -n "$mail" ] && git config --global user.email "$mail"
    else ok "e-mail: $mail"; fi
    if [ -z "$(git config --global init.defaultBranch 2>/dev/null)" ]; then git config --global init.defaultBranch main; fi
}

logins() {
    step "Inloggen (optioneel, kan later ook)"
    local a
    if command -v gh >/dev/null 2>&1; then
        a=$(ask "Nu inloggen bij GitHub? (j/n)")
        case "$a" in [jJyY]*) gh auth login --hostname github.com --git-protocol https --web < /dev/tty ;; esac
    fi
    if command -v firebase >/dev/null 2>&1; then
        a=$(ask "Nu inloggen bij Firebase met je Google-account? (j/n)")
        case "$a" in [jJyY]*) firebase login < /dev/tty ;; esac
    fi
}

summary() {
    step "Overzicht"
    local all=0 line
    for t in "Git:git --version" "Node.js:node -v" "npm:npm -v" "GitHub CLI:gh --version" "Firebase CLI:firebase --version"; do
        local label=${t%%:*} cmd=${t#*:}
        local found=1
        if [ "$label" = Git ]; then has_git || found=0
        else command -v "${cmd%% *}" >/dev/null 2>&1 || found=0; fi
        if [ "$found" = 1 ]; then
            line=$($cmd 2>/dev/null | head -n 1)
            ok "$(printf '%-13s %s' "$label" "$line")"
        else
            warn "$label ontbreekt"; all=1
        fi
    done
    return $all
}

uninstall() {
    local a
    a=$(ask "Alles in $ROOT verwijderen? Je Git-instellingen en logins blijven staan. (j/n)")
    case "$a" in [jJyY]*) ;; *) echo "Afgebroken."; exit 0 ;; esac
    rm -rf "$ROOT"
    for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if [ -f "$rc" ] && grep -qF "$MARK" "$rc"; then
            grep -vF -e "$MARK" -e '.ai-starter' "$rc" > "$rc.ai-tmp"
            cat "$rc.ai-tmp" > "$rc"; rm -f "$rc.ai-tmp"
        fi
    done
    ok "Verwijderd. Open een nieuw Terminal-venster."
}

main() {
    if [ "${1:-}" = "--verwijder" ]; then uninstall; exit 0; fi

    printf '\n%sAI Starter%s: Git, Node.js, GitHub CLI en Firebase CLI\n' "$C_M" "$C_0"
    echo "Installatiemap: $ROOT (geen sudo nodig)"
    mkdir -p "$TMP"
    for d in node/bin npm/bin gh/bin; do
        if [ -d "$ROOT/$d" ]; then add_path "$ROOT/$d"; fi
    done

    install_git      || true
    install_node     || true
    install_gh       || true
    install_firebase || true

    write_rc
    rm -rf "${TMP:?}"
    set_identity
    logins

    echo
    if summary; then
        printf '\n%sKlaar. Open een NIEUW Terminal-venster (en herstart VS Code) zodat alles gevonden wordt.%s\n' "$C_G" "$C_0"
    else
        printf '\n%sNiet alles is gelukt. Draai het script gerust opnieuw: wat al staat wordt overgeslagen.%s\n' "$C_Y" "$C_0"
        printf '%sLukt het dan nog niet, maak een schermafbeelding van dit venster en stuur die naar wie je deze link gaf.%s\n' "$C_Y" "$C_0"
    fi
}

# Alles staat in functies, zodat een half gedownload script via "curl | bash" niets half uitvoert.
main "$@"
