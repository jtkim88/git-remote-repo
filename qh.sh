#!/usr/bin/bash
#===================================================================
# 스크립트명 : qh.sh
# 설명     : NH 영업점 MCA 시스템 간단 설명서 (MCA Quick Help)
# 작성일   : 2026.09.23
# 변경 이력
# - 2026.09.15 : 최초 작성
# - 2026.09.24 : line-up/down 구현
# - 2026.09.30 : 도움말 수정 기능 추가('V' 입력시 해당 도움말 vi 편집 명령 수행)
#===================================================================

source ~/.bashrc 2>/dev/null || true
set -u
arg_stty=$(stty -g 2>/dev/null || echo "")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

INI_FILE=$1:-"$SCRIPT_DIR/qh.ini"
if [[ ! -f "$INI_FILE" ]]; then
    echo "ERROR: $INI_FILE 파일이 없습니다."
    exit 1
fi

# 색상 정의(ANSI Escape Code)
C_RST='\e[0m'          # 색상 초기화
C_REV='\e[7m'          # reverse
C_SEL='\e[1;90;103m'   # 대분류 선택
C_BAK='\e[1;30;43m'    # 소분류 선택
C_MSG='\e[1;91;107m'   # 상태 메시지 (text red, bg white)
CB_PNK='\e[1;45m'      # 특수키
C_RUN='\e[1;37;41m'    # 등록된 명령어 수행
C_YLW='\e[1;33m'       # reserved
C_INP='\e[1;92;100m'   # reserved

current_sec=0          # 대분류(sections) index
current_key=0          # 소분류(submenu) key index
key_count=0            # 대분류의 소분류 개수

# result page
last_rc=0
last_command=""
last_output="(아직 실행된 항목이 없습니다.)"

# 출력(paging)에 필요한 변수
RESULT_LINES=()
current_page=1
total_pages=1
current_line=0

# 화면 레이아웃 라인 수 설정
HEADER_LINES=3
FOOTER_LINES=3
SHOULDER_LINES=2
body_top=0             # HEADER_LINES + SHOULDER_LINES
body_bottom=0          # rows - FOOTER_LINES - 2
body_rows=0
refresh=2              # 0: 화면 그리지 않음, 1: submenu 다시 그림, 2: 전체 화면 다시 그림

rows=24                # 기본값
cols=80                # 기본값

# INI
declare -A SEC=()             # ini에 정의된 section명 배열 -> SEC[current_sec]
declare -A INI=()             # int sec+key 배열 -> INI[current_sec,current_key]
declare -A KEY_CNT=()         # section별 key(=서브메뉴) count -> KEY_CNT[current_sec]

# tag/escape-code 제거
remove_color_tags() {
    local text="$1"

    # tag(<RED>) 제거
    text="${text//<[A-Z]>/}"
    # ansi code 제거
    text="${text//\e\[[0-9;]*m/}"
    echo "$text"
}

# 커스텀 색상 태그를 ANSI code로 치환
replace_color_tags() {
    local text="$1"

    text="${text//<\/RST>/Custom\e[0m}"     # reset
    text="${text//<\/v>/Custom\e[0m}"       # reset

    text="${text//<\/B>/Custom\e[1m}"       # bold
    text="${text//<\/I>/Custom\e[3m}"       # italic (X)
    text="${text//<\/U>/Custom\e[4m}"       # under-line tput smul(시작), tput rmul(종료)
    text="${text//<\/REV>/Custom\e[7m}"     # reverse

    text="${text//<\/BLK>/Custom\e[30m}"    # black
    text="${text//<\/RED>/Custom\e[31m}"    # red
    text="${text//<\/GRN>/Custom\e[32m}"    # green
    text="${text//<\/YLW>/Custom\e[33m}"    # yellow
    text="${text//<\/BLU>/Custom\e[34m}"    # blue
    text="${text//<\/PNK>/Custom\e[35m}"    # purple
    text="${text//<\/SKY>/Custom\e[36m}"    # sky
    text="${text//<\/WHT>/Custom\e[97m}"    # white

    text="${text//<\/B_R>/Custom\e[41m}"    # background red
    text="${text//<\/B_G>/Custom\e[42m}"    # background green
    text="${text//<\/B_Y>/Custom\e[43m}"    # background yellow
    text="${text//<\/B_B>/Custom\e[44m}"    # background blue
    text="${text//<\/B_P>/Custom\e[45m}"    # background purple
    text="${text//<\/B_S>/Custom\e[46m}"    # background sky
    text="${text//<\/B_W>/Custom\e[47m}"    # background white
    echo "$text"
}

# read key code
read_key() {
    local key=""
    IFS= read -rsn1 key1

    key="$key1"
    # ESC 감지
    if [[ "$key1" == $'\e' ]]; then
        IFS= read -rsn1 -t 0.01 key2
        key="$key1$key2"

        # 2바이트 시퀀스인자 확인
        if [[ "$key2" == "[" ]]; then
            IFS= read -rsn1 -t 0.01 key3
            if [[ "$key3" =~ [0-9] ]]; then
                IFS= read -rsn1 -t 0.01 key4
                if [[ "$key4" == "~" ]]; then
                    key="$key$key4"
                else
                    IFS= read -rsn1 -t 0.01 key5
                    key="$key$key5"
                fi
            else
                key="$key$key3"
            fi
        fi
        # ESC [ A 같은 3바이트 시퀀스
        key="$key$key3"
    fi
    # SS3 시퀀스 (ESC O ...) - F1~F4
    elif [[ "$key2" == "O" ]]; then
        IFS= read -rsn1 -t 0.01 key3
        key="$key$key3"
    fi
    fi
    echo "$key"
}

# key code normalize
normalize_key() {
    local key="$1"

    case "$key" in
        # 화살표
        $'\e[A')            echo "UP" ;;
        $'\e[B')            echo "DOWN" ;;
        $'\e[C')            echo "RIGHT" ;;
        $'\e[D')            echo "LEFT" ;;
        $'\e[H'|$'\e[1~')   echo "HOME" ;;
        $'\e[F'|$'\e[4~')   echo "END" ;;
        # F1 ~ F12
        $'\eOP'|$'\e[11~')  echo "F1" ;;
        $'\eOQ'|$'\e[12~')  echo "F2" ;;
        $'\eOR'|$'\e[13~')  echo "F3" ;;
        $'\eOS'|$'\e[14~')  echo "F4" ;;
        $'\e[15~')          echo "F5" ;;
        $'\e[17~')          echo "F6" ;;
        $'\e[18~')          echo "F7" ;;
        $'\e[19~')          echo "F8" ;;
        $'\e[20~')          echo "F9" ;;
        $'\e[21~')          echo "F10" ;;
        $'\e[23~')          echo "F11" ;;
        $'\e[24~')          echo "F12" ;;
        # 기타 키
        $'\e[2~')           echo "INSERT" ;;
        $'\e[3~')           echo "DELETE" ;;
        $'\e[5~'|$'\e[002') echo "PAGE-UP" ;;
        $'\e[6~'|$'\e[006') echo "PAGE-DOWN" ;;
        $'k')               echo "LINE-UP" ;;
        $'j')               echo "LINE-DOWN" ;;
        $'\022')            echo "CTRL+R" ;;
        $'\004')            echo "CTRL+D" ;;
        $' ')               echo "SPACE" ;;
        $'\e')              echo "ESC" ;;
        *)                  echo "$key" ;;
    esac
}

# load ini (INI_FILE)
load_ini() {
    local line="" current_section="" key="" value="" num=0
    while IFS= read -r line || [[ -n "$line" ]]; do

        # 앞뒤 공백제거
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # 빈줄 / 주석
        [[ -z "$line" || "$line" =~ ^# || "$line" =~ ^\; ]] && continue

        # [SECTION] 추출
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            SEC+=("$current_section")
            KEY_CNT["$current_section"]=0
            continue
        fi

        # key=value 추출
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            # key 공백제거
            key="${key//[[:space:]]/}"

            INI["${current_section}.${key}"]="$value"

            # name_N 항목이면 최대 번호 저장
            if [[ "$key" =~ ^name_([0-9]+)$ ]]; then
                num="${BASH_REMATCH[1]}"

                if (( num > KEY_CNT["$current_section"] )); then
                    KEY_CNT["$current_section"]="$num"
                fi
            fi
        fi
    done < "$INI_FILE"
}

get_ini() {
    local section="$1"
    local key="$2"
    printf '%s' "${INI["$section.$key"]-}"
}

cleanup() {
    [[ -n "$org_stty" ]] && stty "$org_stty" 2>/dev/null
    tput cnorm 2>/dev/null    # 커서 다시 표시
    tput rmcup 2>/dev/null    # 원래 터미널 화면 복원
}

resize() {
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)

    # 작은 창 크기의 터미널 보호
    (( rows < 15 )) && rows=24
    (( cols < 60 )) && cols=80

    # Header 다음부터 Content 시작
    body_top=$((HEADER_LINES + SHOULDER_LINES))
    # body_bottom : body 마지막 Line(행번호)
    body_bottom=$((rows - FOOTER_LINES - 1))

    # body_rows : 출력할 body 줄수(행갯수)
    body_rows=$(( body_bottom - body_top ))

    (( body_rows < 1 )) && body_rows=1
}

put_lines() {
    local ch="${1:-=}"
    local line=""
    printf -v line "%*s" "$cols" ""
    printf "%s\n" "${line//$ch}"
}

put_center() {
    local text="$1"
    local width="$2"
    local len=${#text}
    local left=$(( (width - len) / 2 ))
    (( left < 0 )) && left=0
    printf "%*s%s\n" "" "$left" "$text"
}

put_status() {
    local msg="$1"
    local len=${#msg}

    local target_row=$(( rows - 1 ))
    local target_col=3
    local left=$(( cols - len ))

    (( left < 0 )) && left=0
    refresh=0

    tput cup "$target_row" "$target_col"
    printf "%s" "$(( cols - target_col ))" ""    # 기존 잔여 메시지 지우기
    tput cup "$target_row" "$left"
    printf "%s" "${C_MSG}${msg}${C_RST}"
}

# 출력 텍스트를 줄 단위 배열로 분할
make_result_lines() {

    RESULT_LINES=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        RESULT_LINES+=("$line")
    done <<< "$last_output"

    if (( ${#RESULT_LINES[@]} == 0 )); then
        RESULT_LINES+=("")
    fi
}

calc_result_page() {
    local data_rows
    local total_lines

    # 한페이지 Line 수
    data_rows=$((body_rows -3))
    (( data_rows < 1 )) && data_rows=1

    total_lines=${#RESULT_LINES[@]}

    total_pages=$(( (total_lines + data_rows - 1) / data_rows ))
    (( total_pages < 1 )) && total_pages=1
    (( current_page < 1 )) && current_page=1
    (( current_page > total_pages )) && current_page=$total_pages
}

set_result() {
    last_output="$1"
    last_command="${2:-}"
    last_rc="${3:-0}"

    current_page=1
    current_line=0
    make_result_lines
    calc_result_page
}

set_header() {
    local sec=${1:-0}
    local key=${2:-0}

    if (( sec < ${#SEC[@]} )); then
        current_sec=${sec}
        current_key=${key}
        refresh=2
    else
        put_status " FS(($sec+1)) key is not assigned "
    fi
}

header() {
    local line=""
    local i=0
    local COLOR=""

    put_lines "="
    for section in "${SEC[@]}"; do
        if (( i == current_sec )); then
            line+="${C_SEL}[FS$((i+1))]${section}${C_RST}"
        else
            line+="${C_REV}[FS$((i+1))]${section}${C_RST}"
        fi
        (( i++ ))
    done

    printf '%b\n' "$line"
    put_lines "="
}

shoulder() {
    local section="${SEC[$current_sec]}"
    local label=""
    local line=""
    local i
    local shoulder_top=$HEADER_LINES

    key_count="${KEY_CNT[$section]-0}"

    for (( i=1; i<=key_count; i++ )); do
        label="$(get_ini "$section" "name_${i}")"
        [[ -z "$label" ]] && continue
        if (( i == current_key )); then
            line+="${C_BAK} (${i}) $label ${C_RST}"
        else
            line+=" (${i}) $label "
        fi
    done

    tput cup "$shoulder_top" 0
    printf '%b\n' "$line"

    tput cup "$((shoulder_top + 1))" 0
    put_lines "="
}

footer() {
    local footer_top=$((rows - FOOTER_LINES - 1))
    local lmsg rmsg rlen r_col

    local left_str=" [1-9] 하위메뉴 실행 "
    local right_str=" [V] Edit [S] Shell [Q] Exit "
    local right_color_str="${CB_PNK}[V]${C_RST} Edit  ${CB_PNK}[S]${C_RST} Shell  ${CB_PNK}[Q]${C_RST} Exit "

    # 1. 상단 구분선
    tput cup $footer_top 0
    put_lines "="

    # 2. 좌측 및 우측 가이드 출력
    tput cup $((footer_top + 1)) 0
    printf "%s" "$left_str"

    rlen=${#right_str}
    r_col=$(( cols - rlen - 1 ))
    (( r_col < 0 )) && r_col=0

    tput cup $((footer_top + 1)) "$r_col"
    printf "%b\n" "$right_color_str"

    tput cup $((footer_top + 2)) 0
    put_lines "-"
}

disp_body() {
    local data_rows start end i line
    local help_file exec_cmd pmsg plen rmsg rlen r_col

    local cur_sec_str="${SEC[$current_sec]}"
    help_file="$(get_ini "$cur_sec_str" "help_${current_key}")"
    exec_cmd="$(get_ini "$cur_sec_str" "exec_${current_key}")"

    # 도움말 파일 정보 출력
    tput cup "$body_top" 0
    pmsg=" Documents : "$help_file" ("$current_page":"$current_line") ("$current_sec";"$current_key") "
    pmsg=" Document : "$help_file""
    printf '%-*s' "$cols" "$pmsg"

    if [[ -n "$exec_cmd" ]]; then
        rmsg="Press [R] to execute \"$exec_cmd\" "
        rlen=${#rmsg}

        r_col=$(( cols - rlen ))
        (( r_col < 0 )) && r_col=0
        tput cup "$body_top" "$r_col"
        printf "%b\n" "Press ${CB_PNK}[R]${C_RST} to execute '$exec_cmd'"
    else
        printf "\n"
    fi

    put_lines "-"

    # 결과 출력
    data_rows=$((body_rows - 3))
    (( data_rows < 1 )) && data_rows=1

    start=$current_line
    end=$(( start + data_rows - 1 ))

    calc_result_page

    current_page=$(( (start / data_rows) + 1 ))
    (( current_page > total_pages )) && current_page=$total_pages

    for ((i=start; i<=end; i++)); do
        if (( i < ${#RESULT_LINES[@]} )); then
            line="${RESULT_LINES[$i]}"
            printf '%-*.*s\n' "$((cols-1))" "$((cols-1))" "$line"
        else
            printf '%*s\n' "$cols" ""
        fi
    done

    # page navigator
    if (( total_pages > 1 )); then
        put_center "[$current_page/$total_pages]" "$cols"
    else
        put_lines "-"
    fi
    put_status ""
}

# body 출력내용 (도움말) 생성
set_body() {

    local sec="${1:-$current_sec}"
    local key="${2:-$current_key}"
    local help_file="" full_path="" result=""

    current_sec="$sec"
    current_key="$key"

    if (( key > key_count )); then
        put_status " invalid key : (Skey) "
        return
    fi

    refresh=1
    local cur_sec_str="${SEC[$current_sec]}"
    help_file="$(get_ini "$cur_sec_str" "help_${key}")"

    if [[ -n "$help_file" ]]; then
        full_path="$SCRIPT_DIR/$help_file"
        if [[ -f "$full_path" ]]; then
            result="$(expand -t 4 "$full_path" 2>&1)"
            # replace tags to ansi-code
            result="$(replace_color_tags "$result")"
        else
            result="도움말 파일을 찾을 수 없습니다."
        fi
        set_result "$result" "help" "$last_rc"
    fi
}

draw_screen() {
    # 0:ignore, 1:contents only, 2:all screen
    if (( refresh == 2 )); then
        clear
        resize
        header
        shoulder
        set_body "$current_sec" "$current_key"
        disp_body
        footer
    # update contents (shoulder & body)
    elif (( refresh == 1 )); then
        shoulder
        disp_body
    fi
}

# INI에 등록된 command 직접 실행
run_cmd() {
    local sec=$current_sec
    local key=$current_key
    local section="${SEC[$sec]}"
    local label=""
    local cmd=""
    local result=""
    local rc=0

    refresh=1
    if (( sec == 0 )); then
        set_body "$sec" "$key"
        return
    fi

    label="$(get_ini "$section" "name_${key}")"
    if [[ -z "$label" ]]; then
        set_result "[$section] 메뉴 $key 은 존재하지 않습니다." "" 1
        return
    fi

    cmd="$(get_ini "$section" "exec_${key}")"
    if [[ -z "$cmd" ]]; then
        set_result "[$section] [$key] $label : 실행 명령이 없습니다." "" 1
        return
    fi

    result="$(eval "$cmd" 2>&1)"
    rc=$?
    set_result "$result" "$cmd" "$rc"
}

go_right() {
    if (( current_key == 0 )); then
        if (( current_sec < (${#SEC[@]} - 1) )); then
            (( current_sec++ ))
            set_header "$current_sec" "0"
        fi
    elif (( current_key < key_count )); then
        (( current_key++ ))
        refresh=1
        set_body "$current_sec" "$current_key"
    fi
}

go_left() {
    if (( current_key == 0 )); then
        if (( current_sec > 0 )); then
            (( current_sec-- ))
            set_header "$current_sec" "0"
        fi
    elif (( current_key > 1 )); then
        (( current_key-- ))
        refresh=1
        set_body "$current_sec" "$current_key"
    fi
}

go_lineup() {
    if (( current_line > 0 )); then
        (( current_line-- ))
        refresh=1
    fi
}

go_linedown() {
    local total_lines=${#RESULT_LINES[@]}
    local data_rows=$(( body_rows - 3 ))
    (( data_rows < 1 )) && data_rows=1

    if (( current_line + data_rows < total_lines )); then
        (( current_line++ ))
        refresh=1
    fi
}

go_up() {
    if (( current_key != 0 )); then
        set_header "$current_sec" "0"
    else
        refresh=0
    fi
}

go_down() {
    if (( current_key == 0 )); then
        current_key=1
        refresh=1
        set_body "$current_sec" "$current_key"
    else
        refresh=0
    fi
}

go_home() {
    refresh=1
    current_page=1
    current_line=0
}

go_end() {
    refresh=1
    local data_rows=$(( body_rows - 3 ))
    (( data_rows < 1 )) && data_rows=1

    local total_lines=${#RESULT_LINES[@]}

    calc_result_page
    current_page="$total_pages"

    current_line=$(( total_lines - data_rows ))
    (( current_line < 0 )) && current_line=0
}

go_pageup() {
    refresh=1
    local data_rows=$(( body_rows - 3 ))
    (( data_rows < 1 )) && data_rows=1

    current_line=$(( current_line - body_rows ))
    (( current_line < 0 )) && current_line=0
}

go_pagedown() {
    refresh=1
    local data_rows=$(( body_rows - 3 ))
    (( data_rows < 1 )) && data_rows=1

    local total_lines=${#RESULT_LINES[@]}

    if (( current_line + data_rows < total_lines )); then
        current_line=$(( current_line + data_rows ))
    fi
}

# Ctrl+R 사용자 명령 실행 (run user command in my window)
exec_user_command() {
    local cmd=""
    local result=""
    local rc=0
    refresh=2

    while true; do
        clear
        resize
        tput cup 0 0
        put_lines "="

        tput cup 1 0
        put_center "COMMAND EXECUTE" "$cols"

        tput cup 2 0
        put_lines "="

        tput cup 3 0
        printf "%-*.*s\n" "$cols" "$cols" "명령어를 직접 입력하여 실행할 수 있습니다."

        tput cup 4 0
        printf "%-*.*s\n" "$cols" "$cols" "exit / quit : 이전 메뉴로 돌아가기"

        tput cup 5 0
        put_lines "="

        tput cup 6 0
        printf "%-*.*s\n" "$cols" "$cols" "Command : $cmd"

        tput cup 7 0
        put_lines "="

        if [[ -n "$result" ]]; then
            tput cup 9 0
            printf "%b\n" "$result"
        fi

        tput cup 5 $((cols - 2)) 0
        put_lines "-"
        tput cup $((rows - 1)) 0
        printf '%s' " exit / quit 복귀 > "

        read -e cmd
        case "$cmd" in
            exit|quit|q)
                return
                ;;
        esac

        [[ -z "$cmd" ]] && continue

        result="$(eval "$cmd" 2>&1)"
        rc=$?
        result="$result"
        [Return Code : $rc]

        done
}

# Interactive bash 실행 (대화형 sub-shell)
run_bashi() {
    local user_cmd=""
    clear
    echo "==================================================================="
    echo "                        Run Sub Shell Execute"
    echo "==================================================================="
    echo " 일반 shell 명령어를 입력하세요"
    echo " 화면 복귀 : exit 또는 Ctrl+D "
    echo "==================================================================="
    bash -i
    refresh=2
    resize
    clear
}

# Non-Interactive bash 실행(등록된 명령 실행 shell)
run_bashc() {
    local default_cmd="" user_cmd="" exec_cmd=""
    local cur_sec_str="${SEC[$current_sec]}"

    default_cmd="$(get_ini "$cur_sec_str" "exec_${current_key}")"
    if [[ -z "$default_cmd" ]]; then
        put_status " There is no command to execute "
        return
    fi

    # 입력 파라미터 수정할수 있도록 처리 예정
    if [[ "$default_cmd" == *[[:space:]]* ]]; then
        tput cup $(( rows - 1 )) 4
        #printf "Please enter arguments to run : "
        printf "${C_RUN}"
        printf "파라미터를 수정하여 명령어를 수행할 수 있습니다. : "
        printf "${C_REV}"
        IFS= read -e -p " " -i "$default_cmd" user_cmd
        printf "${C_RST}"

        user_cmd="${user_cmd:-$default_cmd}"
        if [[ -n "$user_cmd" && "$user_cmd" =~ ^[a-zA-Z0-9] \-\.\|/]+$ ]]; then
            put_status " input command is not valid "
            return
        fi

        exec_cmd="$user_cmd"
    else
        exec_cmd="$default_cmd"
    fi

    clear
    echo "==================================================================="
    echo "-------------- Shell Command Execute ------------------------------"
    echo -e " Execute : # ${C_RUN}${C_REV}${exec_cmd}${C_RST}"
    echo "==================================================================="
    echo
    bash -c "source ~/.bashrc 2>/dev/null; $exec_cmd"
    echo
    echo "계속하려면 아무키나 누르세요..."
    IFS= read -rsn1
    refresh=2
    resize
    clear
}

# run vim
run_vim() {
    local help_file=""
    local cur_sec_str="${SEC[$current_sec]}"

    help_file="$(get_ini "$cur_sec_str" "help_${current_key}")"
    clear
    bash -c "/usr/bin/vi ${help_file}"
    refresh=2
    resize
    clear
}

main_loop() {
    local input="" key="" num=0 head_index=0

    while true; do

        draw_screen "$refresh"
        tput cup $(( rows - 1 )) 1
        printf '>'
        key=$(read_key)
        input=$(normalize_key "$key")

        case "$input" in
            # Function key
            F1|F2|F3|F4|F5|F6|F7|F8|F9|F10|F11|F12)
                num="${input:1}"
                head_index=$(( num - 1 ))
                set_header "$head_index" "0"
                ;;
            num="1"|input1")
                head_index=$(( num - 1 ))
                set_header "$head_index" "0"
                ;;
            UP)          go_up ;;
            DOWN)        go_down ;;
            RIGHT)       go_right ;;
            LEFT)        go_left ;;
            PAGE-UP)     go_pageup ;;
            PAGE-DOWN)   go_pagedown ;;
            HOME)        go_home ;;
            END)         go_end ;;
            LINE-DOWN)   go_linedown ;;
            LINE-UP)     go_lineup ;;
            [1-9])
                         current_key="$input"
                         set_body "" "$current_key"
                         ;;
            R)           run_bashc ;;
            S)           run_bashi ;;
            V)           run_vim ;;
            CTRL+R)      exec_user_command ;;
            Q|ESC|CTRL+D) break ;;
            *)           put_status " invalid key : $input " ;;
        esac

        # 입력 버퍼 플러시(처리 중 입력 무시)
        while IFS= read -rsn1 -t 0.001 _; do :; done
    done
    clear
    echo " Bye..."
}

main() {

    # 터미널 크기 변경 적용
    trap 'resize' WINCH
    # 종료 처리
    trap cleanup EXIT INT TERM
    load_ini

    # 커서 숨김
    #tput civis
    resize
    main_loop
}

main
