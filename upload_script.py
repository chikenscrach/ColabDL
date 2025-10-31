from viking_file import VikingClient
from pathlib import Path

client = VikingClient(user_hash="")

file_path = Path("")  
uploaded_file = client.upload_file(
    filepath=file_path
) 

print(f"Uploaded file hash: {uploaded_file.hash}")
print(f"Uploaded file name: {uploaded_file.name}")
print(f"Uploaded file URL: {uploaded_file.url}")