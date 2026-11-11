#!/usr/bin/env bash
#
# Renders an appsettings JSON template by replacing every ^^TOKEN^^.
#
# Usage: generate-appsettings.sh <template> <output> [defaults-file]
#
# Value of TOKEN, first match wins:
#   1. environment variable TOKEN, when set and non-empty
#   2. TOKEN=VALUE in the defaults file
#   3. empty string, when TOKEN is set but empty or listed in APPSETTINGS_OPTIONAL_TOKENS
# Anything else is unresolved and fails the run, naming the tokens (never values).
#
# Token placement decides the encoding:
#   inside a JSON string  "..^^TOKEN^^.."  the value is JSON-string escaped
#   outside a string      ^^TOKEN^^        true/yes/on/1 -> true, false/no/off/0/empty -> false,
#                                          a JSON number passes through, anything else fails
#
# Defaults file: KEY=VALUE per line; blank lines and # lines are skipped. A value is never
# evaluated by the shell. ${NAME}, ${NAME:-word} and ${NAME:+word} expand from the environment
# and from keys defined on earlier lines (word may nest further references); $${ is a literal ${.
# A value wrapped in "..." has the quotes removed; one wrapped in '...' is also not expanded.
#
# Names (tokens, keys, references) are upper case: [A-Z_][A-Z0-9_]*.

set -euo pipefail
export LC_ALL=C

die() {
  echo "::error::$*" >&2
  exit 1
}

if [[ "$#" -lt 2 ]] || [[ "$#" -gt 3 ]]; then
  die "Usage: $0 <template> <output> [defaults-file]"
fi

template="$1"
output="$2"
defaults_file="${3:-}"
name_re='^[A-Z_][A-Z0-9_]*$'
number_re='^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
open_ref="\${"
escaped_ref="\$\${"

[[ -f "$template" ]] || die "Template not found: $template"
if [[ -n "$defaults_file" ]] && [[ ! -f "$defaults_file" ]]; then
  die "Defaults file not found: $defaults_file"
fi

declare -A defaults=()
declare -A optional=()
ret=""
line_no=0

optional_list="${APPSETTINGS_OPTIONAL_TOKENS:-}"
read -ra optional_names <<< "${optional_list//,/ }"
for name in "${optional_names[@]}"; do
  optional["$name"]=1
done

lookup() {
  local name="$1"
  if [[ -n "${defaults[$name]+x}" ]]; then
    ret="${defaults[$name]}"
  else
    ret="${!name-}"
  fi
}

expand() {
  local s="$1" out="" i=0 n="${#1}" j name op word value depth
  while [[ "$i" -lt "$n" ]]; do
    if [[ "${s:i:3}" == "$escaped_ref" ]]; then
      out+="$open_ref"
      i=$((i + 3))
      continue
    fi
    if [[ "${s:i:2}" != "$open_ref" ]]; then
      out+="${s:i:1}"
      i=$((i + 1))
      continue
    fi
    j=$((i + 2))
    name=""
    while [[ "$j" -lt "$n" ]] && [[ "${s:j:1}" == [A-Za-z0-9_] ]]; do
      name+="${s:j:1}"
      j=$((j + 1))
    done
    [[ "$name" =~ $name_re ]] || die "Defaults file line ${line_no}: invalid reference name."
    if [[ "${s:j:1}" == "}" ]]; then
      lookup "$name"
      out+="$ret"
      i=$((j + 1))
      continue
    fi
    op="${s:j:2}"
    if [[ "$op" != ":-" ]] && [[ "$op" != ":+" ]]; then
      die "Defaults file line ${line_no}: expected }, :- or :+ after \${${name}."
    fi
    j=$((j + 2))
    local start="$j"
    depth=1
    while [[ "$j" -lt "$n" ]]; do
      if [[ "${s:j:3}" == "$escaped_ref" ]]; then
        j=$((j + 3))
      elif [[ "${s:j:2}" == "$open_ref" ]]; then
        depth=$((depth + 1))
        j=$((j + 2))
      elif [[ "${s:j:1}" == "}" ]]; then
        depth=$((depth - 1))
        if [[ "$depth" -eq 0 ]]; then
          break
        fi
        j=$((j + 1))
      else
        j=$((j + 1))
      fi
    done
    [[ "$depth" -eq 0 ]] || die "Defaults file line ${line_no}: unterminated \${${name}."
    word="${s:start:j-start}"
    lookup "$name"
    value="$ret"
    if [[ "$op" == ":-" ]]; then
      if [[ -n "$value" ]]; then
        out+="$value"
      else
        expand "$word"
        out+="$ret"
      fi
    elif [[ -n "$value" ]]; then
      expand "$word"
      out+="$ret"
    fi
    i=$((j + 1))
  done
  ret="$out"
}

if [[ -n "$defaults_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    if [[ -z "${line//[[:space:]]/}" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    [[ "$line" == *=* ]] || die "Defaults file line ${line_no} has no '='."
    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ $name_re ]] || die "Defaults file line ${line_no} has an invalid key."
    raw="${line#*=}"
    if [[ -n "${!key-}" ]]; then
      defaults["$key"]="${!key}"
      continue
    fi
    if [[ "${#raw}" -ge 2 ]] && [[ "${raw:0:1}" == "'" ]] && [[ "${raw: -1}" == "'" ]]; then
      defaults["$key"]="${raw:1:${#raw}-2}"
      continue
    fi
    if [[ "${#raw}" -ge 2 ]] && [[ "${raw:0:1}" == '"' ]] && [[ "${raw: -1}" == '"' ]]; then
      raw="${raw:1:${#raw}-2}"
    fi
    expand "$raw"
    defaults["$key"]="$ret"
  done < "$defaults_file"
fi

resolve_token() {
  local name="$1"
  if [[ -n "${!name-}" ]]; then
    ret="${!name}"
  elif [[ -n "${defaults[$name]+x}" ]]; then
    ret="${defaults[$name]}"
  elif [[ -n "${!name+x}" ]] || [[ -n "${optional[$name]+x}" ]]; then
    ret=""
  else
    return 1
  fi
}

json_escape() {
  local v="$1" bs="\\" code hex ch rep
  # Quoted replacements stay literal; bash 5.2 patsub_replacement rewrites unquoted \ and &.
  v="${v//"$bs"/"$bs$bs"}"
  v="${v//\"/"$bs\""}"
  v="${v//$'\n'/"${bs}n"}"
  v="${v//$'\r'/"${bs}r"}"
  v="${v//$'\t'/"${bs}t"}"
  v="${v//$'\b'/"${bs}b"}"
  v="${v//$'\f'/"${bs}f"}"
  if [[ "$v" == *[$'\x01'-$'\x1f']* ]]; then
    for code in $(seq 1 31); do
      printf -v hex '%02x' "$code"
      printf -v ch '%b' "\\x${hex}"
      printf -v rep '\\u%04x' "$code"
      v="${v//"$ch"/"$rep"}"
    done
  fi
  ret="$v"
}

normalize_scalar() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "${v,,}" in
    true | yes | on | 1) ret="true" ;;
    false | no | off | 0 | "") ret="false" ;;
    *)
      if [[ "$v" =~ $number_re ]]; then
        ret="$v"
      else
        return 1
      fi
      ;;
  esac
}

IFS= read -r -d '' tpl < "$template" || :
if [[ "$tpl" =~ \^\^[A-Za-z0-9_]*[a-z][A-Za-z0-9_]*\^\^ ]]; then
  die "Template ${template} has a token with lower-case letters; token names are [A-Z_][A-Z0-9_]*."
fi
out=""
in_string=0
escaped=0
i=0
n="${#tpl}"
declare -A unresolved=()
declare -A bad_scalar=()
token_re='^\^\^([A-Z_][A-Z0-9_]*)\^\^'

while [[ "$i" -lt "$n" ]]; do
  c="${tpl:i:1}"
  if [[ "$c" == "^" ]] && [[ "${tpl:i+1:1}" == "^" ]] && [[ "${tpl:i:260}" =~ $token_re ]]; then
    token="${BASH_REMATCH[1]}"
    i=$((i + ${#BASH_REMATCH[0]}))
    if ! resolve_token "$token"; then
      unresolved["$token"]=1
      continue
    fi
    if [[ "$in_string" -eq 1 ]]; then
      json_escape "$ret"
      out+="$ret"
    elif normalize_scalar "$ret"; then
      out+="$ret"
    else
      bad_scalar["$token"]=1
    fi
    continue
  fi
  if [[ "$in_string" -eq 1 ]]; then
    if [[ "$escaped" -eq 1 ]]; then
      escaped=0
    elif [[ "$c" == "\\" ]]; then
      escaped=1
    elif [[ "$c" == '"' ]]; then
      in_string=0
    fi
  elif [[ "$c" == '"' ]]; then
    in_string=1
  fi
  out+="$c"
  i=$((i + 1))
done

failed=0
if [[ "${#unresolved[@]}" -gt 0 ]]; then
  names="$(printf '%s\n' "${!unresolved[@]}" | sort | paste -sd ' ' -)"
  echo "::error::Unresolved tokens in ${template}: ${names}. Set them as environment variables, add them to the defaults file, or list them in APPSETTINGS_OPTIONAL_TOKENS." >&2
  failed=1
fi
if [[ "${#bad_scalar[@]}" -gt 0 ]]; then
  names="$(printf '%s\n' "${!bad_scalar[@]}" | sort | paste -sd ' ' -)"
  echo "::error::Tokens outside a JSON string need a boolean or number value: ${names}. Quote the token in the template for a string value." >&2
  failed=1
fi
if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

tmp="${output}.tmp.$$"
trap 'rm -f "$tmp"' EXIT
cp "$template" "$tmp"
printf '%s' "$out" > "$tmp"

json_error=""
if command -v jq > /dev/null 2>&1; then
  json_error="$(jq empty "$tmp" 2>&1 > /dev/null)" || json_error="${json_error:-invalid}"
elif command -v python3 > /dev/null 2>&1; then
  json_error="$(python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$tmp" 2>&1 > /dev/null)" || json_error="${json_error:-invalid}"
else
  die "Neither jq nor python3 is available to validate ${output}."
fi
if [[ -n "$json_error" ]]; then
  location="$(grep -oE 'line [0-9]+,? column [0-9]+' <<< "$json_error" | head -n1 || :)"
  die "Generated ${output} is not valid JSON${location:+ (${location})}. Check the template's syntax around unquoted tokens."
fi

mv -f "$tmp" "$output"
trap - EXIT
echo "Generated ${output} from ${template}"
