#!/bin/bash

# Remove any old Go installations
echo "Searching for old Go installations..."
sudo rm -rf /usr/local/go
sudo rm -rf /usr/bin/go
sudo rm -rf /usr/lib/go-*

# Reinstall with correct permissions
LATEST_VERSION=$(curl -s https://go.dev/VERSION?m=text | head -n 1)
echo "Installing $LATEST_VERSION..."

wget "https://go.dev/dl/${LATEST_VERSION}.linux-amd64.tar.gz"
sudo tar -C /usr/local -xzf "${LATEST_VERSION}.linux-amd64.tar.gz"

# Update PATH for current user (not root)
if ! grep -q "/usr/local/go/bin" ~/.bashrc; then
    echo '' >> ~/.bashrc
    echo '# Go Programming Language' >> ~/.bashrc
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc
fi

# Also add to ~/.profile
if ! grep -q "/usr/local/go/bin" ~/.profile; then
    echo '' >> ~/.profile
    echo '# Go Programming Language' >> ~/.profile
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
    echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.profile
fi

# Apply immediately
export PATH=$PATH:/usr/local/go/bin

# Clean up
rm "${LATEST_VERSION}.linux-amd64.tar.gz"

# Verify
echo ""
echo "Installation complete!"
/usr/local/go/bin/go version

# Verify installation
echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
/usr/local/go/bin/go version
echo ""
echo "⚠️  IMPORTANT: Run this command now:"
echo ""
echo "    source ~/.bashrc"
echo ""
echo "Or simply close and reopen your terminal."
echo "=========================================="