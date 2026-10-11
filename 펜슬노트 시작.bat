@echo off
chcp 65001 >nul
title 펜슬노트 (이 창을 닫으면 종료됩니다)
cd /d "%~dp0pc"

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js가 설치되어 있지 않습니다. https://nodejs.org 에서 LTS 버전을 설치한 뒤 다시 실행하세요.
  pause
  exit /b 1
)

if not exist node_modules\ws (
  echo 처음 실행이라 필요한 파일을 받는 중입니다...
  call npm install --no-fund --no-audit
  if errorlevel 1 (
    echo 설치에 실패했습니다. 인터넷 연결을 확인하세요.
    pause
    exit /b 1
  )
)

rem 서버가 뜰 시간을 조금 준 뒤 브라우저를 연다 (PENCILNOTE_NO_BROWSER를 지정하면 열지 않음)
if not defined PENCILNOTE_NO_BROWSER start "" /min cmd /c "timeout /t 2 /nobreak >nul & start "" http://localhost:8787"

node server.js
if errorlevel 1 pause
