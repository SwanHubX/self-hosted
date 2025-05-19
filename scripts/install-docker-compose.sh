if ! docker compose version &>/dev/null;  then
    echo "🧐 ${yellow}Docker Compose not found, start installation...${reset}"

    if [[ "$(uname -s)" == "Linux" ]]; then
        if [ -f /etc/os-release ]; then
            source /etc/os-release
            case "$ID" in
                ubuntu)
                    echo "🔧 ${yellow}Adding Docker repository with Aliyun mirror...${reset}"
                    sudo mkdir -p /etc/apt/keyrings
                    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $VERSION_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

                    echo "🔄 ${yellow}Updating package lists...${reset}"
                    sudo apt-get update -qq || {
                        echo "❌ ${red}Failed to update package lists${reset}";
                        exit 1;
                    }

                    echo "📦 ${yellow}Installing docker-compose-plugin...${reset}"
                    sudo apt-get install -qq -y docker-compose-plugin || {
                        echo "❌ ${red}Installation failed, please check network connection${reset}";
                        exit 1;
                    }
                    ;;

                centos)
                    echo "🔧 ${yellow}Adding Docker repository with Aliyun mirror for CentOS...${reset}"
                    sudo yum install -y yum-utils
                    sudo yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

                    echo "🔄 ${yellow}Updating yum cache...${reset}"
                    sudo yum makecache fast -q || {
                        echo "❌ ${red}Failed to update yum cache${reset}";
                        exit 1;
                    }

                    echo "📦 ${yellow}Installing docker-compose-plugin...${reset}"
                    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
                        echo "❌ ${red}Installation failed, please check network connection${reset}";
                        exit 1;
                    }

                    echo "🚀 ${yellow}Starting Docker service...${reset}"
                    sudo systemctl enable --now docker
                    ;;

                *)
                    echo "❌ ${red}Automatic installation only supported on Ubuntu/CentOS${reset}"
                    exit 1
                    ;;
            esac

            echo "✅ ${green}docker-compose-plugin installed successfully!${reset}"
        else
            echo "❌ ${red}Unsupported Linux distribution${reset}"
            exit 1
        fi
    else
        echo "❌ ${red}macOS/Windows detected: Docker Compose is included in Docker Desktop. Please install Docker Desktop${reset}"
        exit 1
    fi
fi
