# shellcheck shell=bash
# Credentials: TD_USER/TD_PASS, else a private credentials file. The password stays in memory
# (TDX_PASSWORD, not exported) and reaches fexp/bteq only on stdin.

tdx_mode_bits() {
    # ls -l permission string -> octal of the rwx bits (setuid/sticky letters count as x)
    local perm=$1 i c bits=0 v
    for ((i = 1; i <= 9; i++)); do
        c=${perm:i:1}
        case $c in r | w | x | s | t) v=1 ;; *) v=0 ;; esac
        bits=$((bits * 2 + v))
    done
    printf '%04o' "$bits"
}

tdx_load_credentials() {
    local user=${TD_USER:-} pass=${TD_PASS:-} path ls_out perm uid mode
    if [[ -n $user && -n $pass ]]; then
        TDX_USER=$user
        TDX_PASSWORD=$pass
        TDX_CRED_SOURCE="environment (TD_USER/TD_PASS)"
        return 0
    fi
    if [[ -n $user || -n $pass ]]; then
        tdx_config_error "only one of TD_USER / TD_PASS is set; set both or neither"
    fi
    [[ -n $S_credentials_file ]] || tdx_config_error "no credentials: set TD_USER and TD_PASS, or [teradata] credentials_file pointing to a chmod 0600 file"
    path=$(tdx_expanduser "$S_credentials_file")
    [[ $path == /* ]] || path="$S_root/$path"
    [[ -e $path ]] || tdx_config_error "credentials_file not found: $path"
    ls_out=$(LC_ALL=C ls -lndL "$path" 2>/dev/null) || tdx_config_error "credentials_file not found: $path"
    read -r perm _ uid _ <<<"$ls_out"
    [[ $uid == "$(id -u)" ]] || tdx_config_error "credentials_file $path is not owned by the current user"
    mode=$(tdx_mode_bits "$perm")
    if (((8#$mode & 8#077) != 0)); then
        tdx_config_error "credentials_file $path has mode $mode; it must not be accessible by group/other (chmod 600)"
    fi
    tdx_ini_read "$path" || tdx_config_error "cannot parse credentials_file $path: $TDX_INI_ERR"
    tdx_get credentials user ""
    TDX_USER=$REPLY
    tdx_get credentials password ""
    TDX_PASSWORD=$REPLY
    INI_V=()
    [[ -n $TDX_USER && -n $TDX_PASSWORD ]] || tdx_config_error "credentials_file $path: [credentials] user and password required"
    TDX_CRED_SOURCE="file $path"
}
