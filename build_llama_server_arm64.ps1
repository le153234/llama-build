# Updated build_llama_server_arm64.ps1

# ...

# Replace git clone with ZIP download
# Line 24: 
# - Old code:
#   git clone <repository-url>
# - New code:
Invoke-WebRequest -Uri '<repository-url>.zip' -OutFile 'file.zip'
Expand-Archive -Path 'file.zip' -DestinationPath 'destination-path'

# ...

# Fix ARM64 cross-compilation HostArch parameter
# Line 152: 
# - Old code:
#   HostArch=arm64
# - New code:
HostArch=amd64

# Rest of the script continues...