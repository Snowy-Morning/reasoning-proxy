@echo off
rem ===== reasoning-proxy config =====
rem Edit values below, then run start.bat again.

rem local listening port
set PROXY_PORT=3120

rem upstream server address and port
set TARGET_HOST=10.0.8.19
set TARGET_PORT=80

rem default reasoning effort (low / medium / high / max)
set REASONING_EFFORT=high

rem kimi reasoning models accept temperature=1 and top_p=0.95 by default
set KIMI_TEMPERATURE=1

rem you can adjust these values if your upstream accepts others
set KIMI_TOP_P=0.95

rem ===== VS Code model list sync =====
rem every value below is optional, an empty value keeps the built-in default

rem chatLanguageModels.json to update. leave empty for the VS Code stable file
rem under %APPDATA%. set this only for a portable or Insiders profile
set LM_CONFIG_PATH=

rem url written into each model entry. leave empty for http://127.0.0.1:PORT/v1
set LM_MODEL_URL=

rem provider block name, only used when the file has to be created
set LM_PROVIDER_NAME=Reasoning Proxy

rem defaults applied to newly added models
set LM_MAX_INPUT_TOKENS=1000000
set LM_MAX_OUTPUT_TOKENS=128000
set LM_TOOL_CALLING=1
set LM_VISION=1

rem per family default for models that chatLanguageModels.json does not list yet.
rem the upstream /v1/models reply carries no such field, so this is where a real
rem number comes from. accepts 1M / 200K / 1000000. empty falls back to the
rem LM_MAX_INPUT_TOKENS default above
set LM_MODEL_CONTEXT=

rem upstream models whose id contains any of these are not added
set LM_SKIP_MODELS=embedding,rerank,reranker,bge,whisper,tts,asr,ocr,ranker,flux,video

rem when set, only ids containing one of these are added
set LM_INCLUDE_MODELS=

rem how many chatLanguageModels.json.bak-* backups to keep for each target file,
rem recycled on every real write. set 0 or less to keep every backup forever
set LM_BACKUP_KEEP=10

rem where those backups live. one sub folder per target file, named after the
rem editor directory plus a digest of the full path. leave empty for
rem %LOCALAPPDATA%\ReasoningProxy\backups, which --uninstall deletes with the rest
set LM_BACKUP_DIR=

rem used only when the proxy is stopped, or before it has seen a VS Code request;
rem otherwise the proxy reuses the Authorization header it already forwards
set LM_API_KEY=

rem 1 = sync on its own once the proxy has seen a VS Code request
set LM_AUTOSYNC=0
