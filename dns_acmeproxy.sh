#!/usr/bin/env sh
# shellcheck disable=SC2034

# This plugin reuses the original function names but talks directly to NetAngels APIs.
# Usage with acme.sh:
#   export ACMEPROXY_USERNAME="ZONE_ID"              # NetAngels DNS zone ID
#   export ACMEPROXY_PASSWORD="NETANGELS_API_KEY"    # API key used to obtain a Bearer token
# Then:
#   acme.sh --issue --dns dns_acmeproxy -d example.com -d '*.example.com'
#
# Notes:
# - ACMEPROXY_PASSWORD is NOT a bearer token, it's an API key used to obtain a bearer token.
# - ACMEPROXY_USERNAME must be the Zone ID (as per NetAngels).
# - ACMEPROXY_ENDPOINT is not used anymore.

dns_acmeproxy_info='NetAngels DNS API (via AcmeProxy plugin name)
 Options:
  ACMEPROXY_USERNAME  Zone ID  (required)
  ACMEPROXY_PASSWORD  API key  (required)
 Docs: https://api-ms.netangels.ru/
 Issues: https://github.com/acmesh-official/acme.sh/issues
 Author: rewritten for NetAngels by ChatGPT
'

# --- Constants (hosts) ---
_NA_TOKEN_ENDPOINT="https://panel.netangels.ru/api/gateway/token/"
_NA_API_BASE="https://api-ms.netangels.ru/api/v1/dns"
_NA_RECORDS_ENDPOINT="$_NA_API_BASE/records"
_NA_ZONES_ENDPOINT="$_NA_API_BASE/zones"

dns_acmeproxy_add() {
  fulldomain="${1}"
  txtvalue="${2}"
  action="present"

  _debug "Calling: _acmeproxy_request() '${fulldomain}' '${txtvalue}' '${action}'"
  _acmeproxy_request "$fulldomain" "$txtvalue" "$action"
}

dns_acmeproxy_rm() {
  fulldomain="${1}"
  txtvalue="${2}"
  action="cleanup"

  _debug "Calling: _acmeproxy_request() '${fulldomain}' '${txtvalue}' '${action}'"
  _acmeproxy_request "$fulldomain" "$txtvalue" "$action"
}

_acmeproxy_request() {
  fulldomain=$1
  txtvalue=$2
  action=$3

  _info "Using NetAngels DNS API"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"
  _debug action "$action"

  # Load credentials from env or account conf
  ACMEPROXY_USERNAME="${ACMEPROXY_USERNAME:-$(_readaccountconf_mutable ACMEPROXY_USERNAME)}"
  ACMEPROXY_PASSWORD="${ACMEPROXY_PASSWORD:-$(_readaccountconf_mutable ACMEPROXY_PASSWORD)}"

  if [ -z "$ACMEPROXY_USERNAME" ]; then
    _err "ACMEPROXY_USERNAME (Zone ID) is not set"
    _err "Please set: export ACMEPROXY_USERNAME=<ZONE_ID>"
    return 1
  fi
  if [ -z "$ACMEPROXY_PASSWORD" ]; then
    _err "ACMEPROXY_PASSWORD (API key) is not set"
    _err "Please set: export ACMEPROXY_PASSWORD=<API_KEY>"
    return 1
  fi

  # Save credentials
  _saveaccountconf_mutable ACMEPROXY_USERNAME "$ACMEPROXY_USERNAME"
  _saveaccountconf_mutable ACMEPROXY_PASSWORD "$ACMEPROXY_PASSWORD"

  # Obtain Bearer token from API key
  token="$(_na_get_token "$ACMEPROXY_PASSWORD")" || return 1
  _debug token "$token"

  # Normalize name (NetAngels examples show FQDN without trailing dot)
  name="$(printf "%s" "$fulldomain" | sed 's/\.$//')"

  case "$action" in
    present)
      # Create TXT record
      export _H1="Authorization: $token"
      export _H2="Accept: application/json"
      export _H3="Content-Type: application/json"

      data=$(printf '{"name": %s, "type": "TXT", "value": %s}' \
        "$(_json_encode "$name")" "$(_json_encode "$txtvalue")")

      _debug data "$data"
      response="$(_post "$data" "$_NA_RECORDS_ENDPOINT/" "" "POST")"
      _debug response "$response"

      # Extract created ID
      rid="$(_na_extract_id "$response")"
      if [ -n "$rid" ]; then
        _info "Successfully created TXT record id=$rid"
        # Save record id per (name, value)
        key="$(_na_record_key "$name" "$txtvalue")"
        _na_state_put "$key" "$rid"
        return 0
      fi

      if echo "$response" | grep -F "\"$txtvalue\"" >/dev/null 2>&1; then
        _info "Successfully created the TXT record"
        return 0
      else
        _err "Error creating TXT record"
        _err "$response"
        return 1
      fi
      ;;

    cleanup)
      # Try to read saved record id first
      key="$(_na_record_key "$name" "$txtvalue")"
      rid="$(_na_state_get "$key")"

      if [ -n "$rid" ]; then
        _debug "Found saved record id: $rid, deleting..."
        if _na_delete_record_by_id "$token" "$rid"; then
          _info "Deleted TXT record id=$rid"
          _na_state_del "$key"
          return 0
        else
          _err "Failed to delete TXT record id=$rid (will try to find by listing)"
          # fallthrough to listing search
        fi
      fi

      # Find by listing the zone and matching name+value
      _debug "Listing zone records to find the TXT record..."
      rid_list="$(_na_find_record_ids "$token" "$ACMEPROXY_USERNAME" "$name" "$txtvalue")"
      if [ -z "$rid_list" ]; then
        _info "No matching TXT record found for cleanup (name=$name)."
        return 0
      fi

      ok=0
      for rid in $rid_list; do
        if _na_delete_record_by_id "$token" "$rid"; then
          _info "Deleted TXT record id=$rid"
          ok=1
        else
          _err "Failed deleting TXT record id=$rid"
        fi
      done

      if [ "$ok" -eq 1 ]; then
        return 0
      else
        return 1
      fi
      ;;

    *)
      _err "Unknown action: $action"
      return 1
      ;;
  esac
}

####################  Private functions below ##################################

# --- Transient state (store record IDs in a tmp file) ---

_na_state_file() {
  # старайся класть рядом с рабочей директорией acme.sh, иначе /tmp
  if [ -n "$LE_WORKING_DIR" ] && [ -d "$LE_WORKING_DIR" ]; then
    printf "%s/.na_acmeproxy_state" "$LE_WORKING_DIR"
  else
    printf "/tmp/.na_acmeproxy_state"
  fi
}

_na_state_put() {
  key="$1"
  val="$2"
  f="$(_na_state_file)"
  # гарантируем существование файла
  : > "$f" 2>/dev/null || return 0
  # удалим старое значение ключа, если есть
  if [ -f "$f" ]; then
    grep -v "^$key=" "$f" 2>/dev/null > "$f.tmp" || :
    mv "$f.tmp" "$f" 2>/dev/null || :
  fi
  printf "%s=%s\n" "$key" "$val" >> "$f"
}

_na_state_get() {
  key="$1"
  f="$(_na_state_file)"
  [ -r "$f" ] || return 1
  sed -n "s/^$key=//p" "$f" | head -n1
}

_na_state_del() {
  key="$1"
  f="$(_na_state_file)"
  [ -w "$f" ] || return 0
  grep -v "^$key=" "$f" 2>/dev/null > "$f.tmp" || :
  mv "$f.tmp" "$f" 2>/dev/null || :
}

_na_get_token() {
  # Input: API key
  api_key="$1"
  export _H1="Content-Type: application/x-www-form-urlencoded"
  export _H2="Accept: application/json"

  resp="$(_post "api_key=$api_key" "$_NA_TOKEN_ENDPOINT" "" "POST")"
  _debug2 "token_resp" "$resp"

  token="$(printf "%s" "$resp" | tr -d '\r\n' \
    | _egrep_o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"

  if [ -z "$token" ]; then
    _err "Failed to obtain token from NetAngels gateway"
    _err "$resp"
    return 1
  fi

  case "$token" in
    [Bb][Ee][Aa][Rr][Ee][Rr]\ *) : ;;
    *) token="Bearer $token" ;;
  esac

  printf "%s" "$token"
}

_na_extract_id() {
  # Extract first numeric id from JSON
  # Output: id or empty
  printf "%s" "$1" | _egrep_o '"id"[[:space:]]*:[[:space:]]*[0-9]+' \
    | sed -E 's/.*: *([0-9]+).*/\1/' | head -n1
}

_na_record_key() {
  # Create a stable account-conf key for record id, based on name+value
  name="$1"
  val="$2"
  sname="$(printf "%s" "$name" | sed 's/[^A-Za-z0-9_]/_/g')"
  vhash="$(printf "%s" "$val" | _base64 | sed 's/[^A-Za-z0-9_]/_/g' | cut -c1-32)"
  printf "ACMEPROXY_ID_%s_%s" "$sname" "$vhash"
}

_na_delete_record_by_id() {
  # Args: token id
  token="$1"
  rid="$2"

  export _H1="Authorization: $token"
  export _H2="Accept: application/json"

  resp="$(_post "" "$_NA_RECORDS_ENDPOINT/$rid/" "" "DELETE")"
  _debug "delete_resp" "$resp"

  # If response contains the same id or is empty-success, consider ok
  if printf "%s" "$resp" | grep -E "\"id\"[[:space:]]*:[[:space:]]*$rid" >/dev/null 2>&1; then
    return 0
  fi

  # Some APIs may return empty body on 200; try to detect via presence of error keywords
  if [ -z "$resp" ] || ! printf "%s" "$resp" | grep -qi "error"; then
    return 0
  fi

  return 1
}

_na_find_record_ids() {
  # Args: token zone_id name value
  token="$1"
  zone_id="$2"
  name="$3"
  value="$4"

  export _H1="Authorization: $token"
  export _H2="Accept: application/json"

  url="$_NA_ZONES_ENDPOINT/$zone_id/records/"
  resp="$(_get "$url")"
  _debug "list_resp" "$resp"

  # Make it easier to scan entity-by-entity
  entities="$(printf "%s" "$resp" | tr -d '\n' | sed 's/},{/}\n{/g')"

  printf "%s\n" "$entities" | while IFS= read -r obj; do
    # Expect name, type TXT and details.value matches
    echo "$obj" | grep -q '"type"[[:space:]]*:[[:space:]]*"TXT"' || continue
    echo "$obj" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" || continue

    # Match value inside details; accept both "details":{"value":"..."} or any spacing
    echo "$obj" | tr -d '\n' | grep -q "\"value\"[[:space:]]*:[[:space:]]*\"$(_escape_regex "$value")\"" || continue

    rid="$(printf "%s" "$obj" | _egrep_o '"id"[[:space:]]*:[[:space:]]*[0-9]+' | sed -E 's/.*: *([0-9]+).*/\1/' | head -n1)"
    [ -n "$rid" ] && printf "%s\n" "$rid"
  done
}

_escape_regex() {
  # Escape for basic grep -E usage
  printf "%s" "$1" | sed -e 's/[][\.^$*/]/\\&/g'
}

# acme.sh provides _json_encode, but define fallback if needed
_json_encode() {
  # Very small JSON string escaper for acme.sh context
  s="$1"
  s="$(printf "%s" "$s" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf "\"%s\"" "$s"
}
