#!/usr/bin/env bash
set -euo pipefail

# ─── Colors & Helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { printf "${BLUE}▸${RESET} %s\n" "$*"; }
success() { printf "${GREEN}✔${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*"; }
error()   { printf "${RED}✖${RESET} %s\n" "$*" >&2; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${RESET}\n\n" "$*"; }

ask() {
    local prompt="$1" var="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        printf "${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$prompt" "$default"
    else
        printf "${BOLD}%s${RESET}: " "$prompt"
    fi
    read -r "$var"
    if [[ -z "${!var}" && -n "$default" ]]; then
        eval "$var='$default'"
    fi
}

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        printf "${BOLD}%s${RESET} ${DIM}[Y/n]${RESET}: " "$prompt"
    else
        printf "${BOLD}%s${RESET} ${DIM}[y/N]${RESET}: " "$prompt"
    fi
    read -r yn
    yn="${yn:-$default}"
    [[ "$yn" =~ ^[Yy] ]]
}

spinner() {
    local pid=$1 msg="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}%s${RESET} %s" "${spin:i++%10:1}" "$msg"
        sleep 0.1
    done
    printf "\r"
}

# ─── OS Detection ────────────────────────────────────────────────────────────

detect_os() {
    case "$(uname -s)" in
        Linux*)  OS="linux" ;;
        Darwin*) OS="macos" ;;
        *)       error "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac

    if [[ "$OS" == "linux" ]]; then
        if command -v apt-get &>/dev/null; then
            PKG_MANAGER="apt"
        elif command -v dnf &>/dev/null; then
            PKG_MANAGER="dnf"
        elif command -v pacman &>/dev/null; then
            PKG_MANAGER="pacman"
        elif command -v apk &>/dev/null; then
            PKG_MANAGER="apk"
        else
            PKG_MANAGER="unknown"
        fi
    else
        PKG_MANAGER="brew"
    fi
}

# ─── Welcome ─────────────────────────────────────────────────────────────────

show_welcome() {
    printf "\n"
    printf "${BOLD}${CYAN}"
    cat << 'BANNER'
   ╔══════════════════════════════════════════════╗
   ║                                              ║
   ║   Claude Code + GitHub Pages Quick Start     ║
   ║                                              ║
   ║   Set up your dev environment and publish    ║
   ║   your first website in minutes.             ║
   ║                                              ║
   ╚══════════════════════════════════════════════╝
BANNER
    printf "${RESET}\n"
}

# ─── Experience Level ────────────────────────────────────────────────────────

ask_experience() {
    header "About You"

    printf "  What's your experience level with the command line?\n\n"
    printf "  ${BOLD}1)${RESET} ${GREEN}Beginner${RESET}    — I'm new to the terminal\n"
    printf "  ${BOLD}2)${RESET} ${YELLOW}Intermediate${RESET} — I've used git and basic commands\n"
    printf "  ${BOLD}3)${RESET} ${CYAN}Advanced${RESET}     — I live in the terminal\n\n"

    local level
    ask "Pick a number" level "1"

    case "$level" in
        1) EXPERIENCE="beginner" ;;
        2) EXPERIENCE="intermediate" ;;
        3) EXPERIENCE="advanced" ;;
        *) EXPERIENCE="beginner" ;;
    esac

    success "Got it — tailoring the experience for ${BOLD}$EXPERIENCE${RESET} level."

    if [[ "$EXPERIENCE" == "beginner" ]]; then
        VERBOSE=true
        printf "\n  ${DIM}Don't worry — I'll explain each step as we go.${RESET}\n"
    else
        VERBOSE=false
    fi
}

# ─── Dependency Checks ──────────────────────────────────────────────────────

check_command() {
    command -v "$1" &>/dev/null
}

ensure_curl_or_wget() {
    if check_command curl; then
        FETCH="curl -fsSL"
    elif check_command wget; then
        FETCH="wget -qO-"
    else
        error "Neither curl nor wget found. Please install one first."
        exit 1
    fi
}

ensure_git() {
    if check_command git; then
        success "git is already installed ($(git --version | cut -d' ' -f3))"
        return
    fi

    header "Installing Git"
    [[ "$VERBOSE" == true ]] && info "Git is a version control tool that tracks changes to your code."

    case "$PKG_MANAGER" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y -qq git ;;
        dnf)    sudo dnf install -y -q git ;;
        pacman) sudo pacman -S --noconfirm git ;;
        apk)    sudo apk add --quiet git ;;
        brew)   brew install git ;;
        *)      error "Can't auto-install git. Please install it manually."; exit 1 ;;
    esac

    success "git installed ($(git --version | cut -d' ' -f3))"
}

# ─── Install Node.js (needed for Claude CLI) ────────────────────────────────

ensure_node() {
    if check_command node; then
        local node_version
        node_version="$(node --version)"
        local major="${node_version#v}"
        major="${major%%.*}"
        if (( major >= 18 )); then
            success "Node.js is already installed ($node_version)"
            return
        else
            warn "Node.js $node_version is too old (need >= 18). Upgrading..."
        fi
    fi

    header "Installing Node.js"
    [[ "$VERBOSE" == true ]] && info "Node.js is a JavaScript runtime. Claude Code needs it to run."

    if check_command fnm; then
        fnm install 22 && fnm use 22
    elif check_command nvm; then
        nvm install 22 && nvm use 22
    else
        info "Installing Node.js 22 via NodeSource..."
        if [[ "$OS" == "macos" ]]; then
            brew install node@22
        else
            $FETCH https://deb.nodesource.com/setup_22.x | sudo -E bash -
            sudo apt-get install -y -qq nodejs
        fi
    fi

    success "Node.js installed ($(node --version))"
}

# ─── Install GitHub CLI ─────────────────────────────────────────────────────

install_gh() {
    if check_command gh; then
        success "GitHub CLI is already installed ($(gh --version | head -1 | awk '{print $3}'))"
        return
    fi

    header "Installing GitHub CLI"
    [[ "$VERBOSE" == true ]] && info "The GitHub CLI lets you interact with GitHub from the terminal."

    case "$OS" in
        macos)
            brew install gh
            ;;
        linux)
            case "$PKG_MANAGER" in
                apt)
                    (type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
                        && sudo mkdir -p -m 755 /etc/apt/keyrings \
                        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
                        && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
                        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null \
                        && sudo apt update -qq \
                        && sudo apt install gh -y -qq
                    ;;
                dnf)
                    sudo dnf install -y -q 'dnf-command(config-manager)' \
                        && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
                        && sudo dnf install -y -q gh
                    ;;
                pacman)
                    sudo pacman -S --noconfirm github-cli
                    ;;
                *)
                    info "Installing gh via prebuilt binary..."
                    local gh_ver="2.67.0"
                    local arch
                    arch="$(uname -m)"
                    [[ "$arch" == "x86_64" ]] && arch="amd64"
                    [[ "$arch" == "aarch64" ]] && arch="arm64"
                    $FETCH "https://github.com/cli/cli/releases/download/v${gh_ver}/gh_${gh_ver}_linux_${arch}.tar.gz" \
                        | sudo tar xz -C /usr/local/bin --strip-components=2 "gh_${gh_ver}_linux_${arch}/bin/gh"
                    ;;
            esac
            ;;
    esac

    success "GitHub CLI installed ($(gh --version | head -1 | awk '{print $3}'))"
}

# ─── Install Claude Code ────────────────────────────────────────────────────

install_claude() {
    if check_command claude; then
        success "Claude Code is already installed"
        return
    fi

    header "Installing Claude Code"
    [[ "$VERBOSE" == true ]] && info "Claude Code is an AI coding assistant that runs in your terminal."

    npm install -g @anthropic-ai/claude-code@latest 2>/dev/null

    if check_command claude; then
        success "Claude Code installed"
    else
        error "Claude Code installation failed. Try running: npm install -g @anthropic-ai/claude-code@latest"
        exit 1
    fi
}

# ─── GitHub Account Setup ───────────────────────────────────────────────────

setup_github() {
    header "GitHub Setup"

    # Check if already authenticated
    if gh auth status &>/dev/null 2>&1; then
        local gh_user
        gh_user="$(gh api user -q .login 2>/dev/null || echo "")"
        if [[ -n "$gh_user" ]]; then
            success "Already logged in to GitHub as ${BOLD}$gh_user${RESET}"
            GH_USER="$gh_user"
            return
        fi
    fi

    printf "\n"
    if ask_yn "Do you already have a GitHub account?"; then
        info "Let's log you in."
        [[ "$VERBOSE" == true ]] && printf "\n  ${DIM}A browser window will open for you to authorize the GitHub CLI.${RESET}\n\n"

        gh auth login --web --git-protocol https

        GH_USER="$(gh api user -q .login 2>/dev/null || echo "user")"
        success "Logged in as ${BOLD}$GH_USER${RESET}"
    else
        header "Creating a GitHub Account"

        printf "  GitHub is where your code and website will live.\n"
        printf "  Let's create your free account.\n\n"

        printf "  ${BOLD}Step 1:${RESET} Open your browser and go to:\n\n"
        printf "         ${CYAN}${BOLD}https://github.com/signup${RESET}\n\n"

        printf "  ${BOLD}Step 2:${RESET} Follow the prompts:\n"
        printf "         • Enter your email address\n"
        printf "         • Create a password (15+ chars, or 8+ with a number & lowercase)\n"
        printf "         • Pick a username (this will be in your website URL)\n"
        printf "         • Solve the puzzle to verify you're human\n"
        printf "         • Click ${BOLD}\"Create account\"${RESET}\n\n"

        printf "  ${BOLD}Step 3:${RESET} Check your email for a verification code and enter it\n\n"

        printf "  ${BOLD}Step 4:${RESET} You can skip the personalization — click ${BOLD}\"Skip\"${RESET} at the bottom\n\n"

        printf "  ${DIM}Take your time. This script will wait for you.${RESET}\n\n"

        # Open browser if possible
        if check_command xdg-open; then
            xdg-open "https://github.com/signup" 2>/dev/null &
        elif check_command open; then
            open "https://github.com/signup" 2>/dev/null &
        fi

        printf "  ${YELLOW}Press Enter when you've created your account...${RESET}"
        read -r

        printf "\n"
        info "Now let's log in from the terminal."
        [[ "$VERBOSE" == true ]] && printf "\n  ${DIM}This will open a browser window to connect your account.${RESET}\n\n"

        gh auth login --web --git-protocol https

        GH_USER="$(gh api user -q .login 2>/dev/null || echo "user")"
        success "Logged in as ${BOLD}$GH_USER${RESET}"
    fi

    # Configure git identity if not set
    if [[ -z "$(git config --global user.name 2>/dev/null)" ]]; then
        local name email
        name="$(gh api user -q .name 2>/dev/null || echo "")"
        email="$(gh api user -q .email 2>/dev/null || echo "")"

        if [[ -z "$name" ]]; then
            ask "Your name (for git commits)" name "$GH_USER"
        fi
        if [[ -z "$email" ]]; then
            ask "Your email (for git commits)" email "${GH_USER}@users.noreply.github.com"
        fi

        git config --global user.name "$name"
        git config --global user.email "$email"
        success "Git identity configured: $name <$email>"
    fi
}

# ─── Create & Deploy Hello World Site ────────────────────────────────────────

create_site() {
    header "Creating Your Website"

    local repo_name
    ask "What should we name the repository?" repo_name "${GH_USER}.github.io"

    local site_dir="$HOME/$repo_name"

    if [[ -d "$site_dir" ]]; then
        warn "Directory $site_dir already exists."
        if ! ask_yn "Overwrite it?" "n"; then
            info "Skipping site creation."
            return
        fi
        rm -rf "$site_dir"
    fi

    [[ "$VERBOSE" == true ]] && info "Creating project directory at $site_dir"

    mkdir -p "$site_dir"
    cd "$site_dir"
    git init -q

    # Create the website
    cat > index.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hello, World!</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
            background: #0f0f1a;
            color: #e0e0e0;
            overflow: hidden;
        }

        .container {
            text-align: center;
            animation: fadeIn 1s ease-out;
        }

        h1 {
            font-size: clamp(2.5rem, 8vw, 5rem);
            font-weight: 800;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin-bottom: 1rem;
        }

        p {
            font-size: 1.25rem;
            color: #888;
            margin-bottom: 2rem;
        }

        .badge {
            display: inline-block;
            padding: 0.5rem 1.5rem;
            border-radius: 999px;
            background: rgba(102, 126, 234, 0.1);
            border: 1px solid rgba(102, 126, 234, 0.3);
            color: #667eea;
            font-size: 0.875rem;
            font-weight: 500;
        }

        .particles {
            position: fixed;
            inset: 0;
            pointer-events: none;
            z-index: -1;
        }

        .particle {
            position: absolute;
            width: 4px;
            height: 4px;
            background: rgba(102, 126, 234, 0.3);
            border-radius: 50%;
            animation: float linear infinite;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(20px); }
            to   { opacity: 1; transform: translateY(0); }
        }

        @keyframes float {
            from { transform: translateY(100vh) rotate(0deg); opacity: 0; }
            10%  { opacity: 1; }
            90%  { opacity: 1; }
            to   { transform: translateY(-10vh) rotate(720deg); opacity: 0; }
        }
    </style>
</head>
<body>
    <div class="particles" id="particles"></div>
    <div class="container">
        <h1>Hello, World!</h1>
        <p>Your site is live. Start building something amazing.</p>
        <span class="badge">Built with Claude Code</span>
    </div>
    <script>
        const container = document.getElementById('particles');
        for (let i = 0; i < 30; i++) {
            const p = document.createElement('div');
            p.className = 'particle';
            p.style.left = Math.random() * 100 + '%';
            p.style.animationDuration = (8 + Math.random() * 12) + 's';
            p.style.animationDelay = (Math.random() * 10) + 's';
            p.style.width = p.style.height = (2 + Math.random() * 4) + 'px';
            container.appendChild(p);
        }
    </script>
</body>
</html>
HTML

    success "Created index.html"

    # Commit
    git add -A
    git commit -q -m "Initial commit: Hello World site"
    success "Committed to git"

    # Create GitHub repo and push
    [[ "$VERBOSE" == true ]] && info "Creating a repository on GitHub and pushing your site..."

    # Determine if this is a user pages site (username.github.io)
    local is_user_site=false
    if [[ "$repo_name" == "${GH_USER}.github.io" ]]; then
        is_user_site=true
    fi

    gh repo create "$repo_name" --public --source=. --push --description "My first website, built with Claude Code" 2>/dev/null \
        || { error "Failed to create repository. It may already exist."; return 1; }

    success "Pushed to GitHub"

    # Enable GitHub Pages
    local branch
    branch="$(git branch --show-current)"

    if [[ "$is_user_site" == true ]]; then
        # For user pages sites (username.github.io), GitHub auto-enables pages from main
        info "User pages site detected — GitHub will auto-enable Pages on ${BOLD}$branch${RESET}."
    else
        # For project sites, enable Pages via API
        gh api --method POST "repos/${GH_USER}/${repo_name}/pages" \
            -f "source[branch]=$branch" -f "source[path]=/" 2>/dev/null \
            || warn "Could not auto-enable Pages. You may need to enable it manually in repo Settings > Pages."
    fi

    success "GitHub Pages enabled"

    # Build the URL
    local site_url
    if [[ "$is_user_site" == true ]]; then
        site_url="https://${GH_USER}.github.io"
    else
        site_url="https://${GH_USER}.github.io/${repo_name}"
    fi

    SITE_URL="$site_url"
    SITE_DIR="$site_dir"
    REPO_NAME="$repo_name"
}

# ─── Finish ──────────────────────────────────────────────────────────────────

show_finish() {
    printf "\n"
    printf "${BOLD}${GREEN}"
    cat << 'BANNER'
   ╔══════════════════════════════════════════════╗
   ║                                              ║
   ║          You're all set!                     ║
   ║                                              ║
   ╚══════════════════════════════════════════════╝
BANNER
    printf "${RESET}\n"

    printf "  ${BOLD}Your website:${RESET}     ${CYAN}${SITE_URL}${RESET}\n"
    printf "  ${BOLD}Project folder:${RESET}   ${SITE_DIR}\n"
    printf "  ${BOLD}GitHub repo:${RESET}      https://github.com/${GH_USER}/${REPO_NAME}\n\n"

    printf "  ${DIM}It may take a minute or two for GitHub Pages to go live.${RESET}\n\n"

    header "What's Next"

    printf "  ${BOLD}Edit your site with Claude Code:${RESET}\n\n"
    printf "    cd %s\n" "$SITE_DIR"
    printf "    claude\n\n"

    printf "  ${DIM}Try asking Claude:${RESET}\n"
    printf "    \"Add an about page\"\n"
    printf "    \"Make it a portfolio site\"\n"
    printf "    \"Add a dark mode toggle\"\n\n"

    printf "  ${BOLD}Push changes:${RESET}\n\n"
    printf "    git add -A && git commit -m \"update\" && git push\n\n"

    if [[ "$EXPERIENCE" == "beginner" ]]; then
        header "Quick Reference"
        printf "  ${BOLD}ls${RESET}          — list files in the current folder\n"
        printf "  ${BOLD}cd folder${RESET}   — move into a folder\n"
        printf "  ${BOLD}cd ..${RESET}       — go back one folder\n"
        printf "  ${BOLD}claude${RESET}      — start Claude Code AI assistant\n"
        printf "  ${BOLD}gh repo view --web${RESET}  — open your repo in the browser\n\n"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    show_welcome
    detect_os
    ask_experience
    ensure_curl_or_wget
    ensure_git
    ensure_node
    install_gh
    install_claude
    setup_github
    create_site
    show_finish
}

main "$@"
