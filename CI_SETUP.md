# GitHub Actions CI Setup

To correctly build release APKs using the provided GitHub Actions workflows, you need to configure the following repository secrets.

## Required Secrets

Go to your GitHub repository -> **Settings** -> **Secrets and variables** -> **Actions** -> **New repository secret**.

1. **`ANDROID_KEYSTORE_BASE64`**: The base64-encoded string of your `upload-keystore.jks` file.
2. **`ANDROID_KEYSTORE_PASSWORD`**: The store password for your keystore.
3. **`ANDROID_KEY_PASSWORD`**: The key password for your keystore (often the same as the store password).
4. **`ANDROID_KEY_ALIAS`**: The alias of your key (e.g., `peachpay`).
5. **`SUPABASE_URL`**: Your Supabase project URL.
6. **`SUPABASE_ANON_KEY`**: Your Supabase anonymous public key.

## Generating the Keystore
You can generate the keystore by running the **Make Keystore** workflow in GitHub Actions (via `workflow_dispatch`). Download the resulting artifact, which contains `upload-keystore.jks` and a text file with your passwords and alias.

## Base64 Encoding the Keystore on Windows PowerShell
To get the base64 string of `upload-keystore.jks` for the `ANDROID_KEYSTORE_BASE64` secret, use the following PowerShell command in the directory containing the downloaded `.jks` file:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks")) | Set-Clipboard
```
This will copy the base64 string directly to your clipboard. You can then paste it into the GitHub Secret value field.
