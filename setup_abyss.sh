#!/data/data/com.termux/files/usr/bin/bash
# ==========================================================
#  Abyss Downloader - instalador automático para Termux
#  Versión ultra-automatizada: solo comando único
# ==========================================================
VERSION="2.0.0"
JAR_URL="https://github.com/Alejandrolopez1989/app-descargar-id-abyss/releases/latest/download/abyss-dl.jar"
SCRIPT_URL="https://raw.githubusercontent.com/Alejandrolopez1989/app-descargar-id-abyss/main/setup_abyss.sh"
WORKDIR="$HOME/abyss_server"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   📥 Abyss Downloader  v$VERSION      ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ---------- Auto-actualización del script ----------
REMOTE_VER=$(curl -fsSL "$SCRIPT_URL" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)
LOCAL_VER=$(grep -m1 '^VERSION=' "$0" 2>/dev/null | cut -d'"' -f2)
if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
    echo "🔄 Actualización detectada ($LOCAL_VER -> $REMOTE_VER). Descargando..."
    curl -fsSL -o "$0" "$SCRIPT_URL" && chmod +x "$0" && exec "$0"
fi

# ---------- Dependencias ----------
echo "🔧 Instalando dependencias..."
pkg update -y >/dev/null 2>&1
pkg install -y python openjdk-21 net-tools >/dev/null 2>&1
pip install -q flask >/dev/null 2>&1
echo "   ✅ Listo"

# ---------- Estructura ----------
mkdir -p "$WORKDIR/templates"
cd "$WORKDIR"

# ---------- JAR ----------
if [ -f "$WORKDIR/abyss-dl.jar" ]; then
    echo "✅ JAR ya presente"
elif [ -f /sdcard/Download/abyss-dl.jar ]; then
    cp /sdcard/Download/abyss-dl.jar "$WORKDIR/abyss-dl.jar"
    echo "✅ JAR copiado desde Descargas"
else
    echo "⬇️  Descargando abyss-dl.jar..."
    curl -fL -o "$WORKDIR/abyss-dl.jar" "$JAR_URL" || { echo "❌ No se pudo descargar el JAR"; exit 1; }
    echo "   ✅ JAR descargado"
fi

# ---------- server.py ----------
cat > "$WORKDIR/server.py" << 'SERVER_EOF'
import os
import subprocess
import threading
import uuid
import queue
from flask import Flask, render_template, request, jsonify, Response

app = Flask("abyss")

JAR_PATH = os.path.expanduser("~/abyss_server/abyss-dl.jar")
DEFAULT_FOLDER = "/sdcard/Download"

active_processes = {}
job_queues = {}
lock = threading.Lock()


def run_download(job_id, cmd):
    q = job_queues[job_id]
    try:
        proc = subprocess.Popen(
            ["java", "-jar", JAR_PATH] + cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=DEFAULT_FOLDER,
        )
        with lock:
            active_processes[job_id] = proc
        for linea in proc.stdout:
            q.put(linea)
        proc.wait()
        q.put("[END]:" + str(proc.returncode))
    except Exception as e:
        q.put("[ERROR]:" + str(e))
    finally:
        with lock:
            active_processes.pop(job_id, None)
        q.put(None)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/descargar", methods=["POST"])
def descargar():
    data = request.get_json(force=True) or {}
    entrada = data.get("entrada", "").strip()
    if not entrada:
        return jsonify({"error": "Ingresa el ID o URL del video."}), 400

    resolucion = data.get("resolucion", "ninguna")
    carpeta = data.get("carpeta", DEFAULT_FOLDER).strip() or DEFAULT_FOLDER
    nombre = data.get("nombre", "").strip()
    conexiones = data.get("conexiones", 4)
    verbose = data.get("verbose", False)
    headers = data.get("headers", [])

    cmd = [entrada]
    if resolucion and resolucion != "ninguna":
        cmd.append(resolucion)
    for linea in headers:
        linea = linea.strip()
        if linea:
            cmd.extend(["-H", linea])
    if nombre:
        cmd.extend(["-o", os.path.join(carpeta, nombre)])
    if conexiones:
        cmd.extend(["-c", str(conexiones)])
    if verbose:
        cmd.append("--verbose")

    job_id = str(uuid.uuid4())
    job_queues[job_id] = queue.Queue()
    t = threading.Thread(target=run_download, args=(job_id, cmd), daemon=True)
    t.start()
    return jsonify({"job_id": job_id})


@app.route("/logs/<job_id>")
def logs(job_id):
    q = job_queues.get(job_id)
    if not q:
        return "Job no encontrado", 404

    def generate():
        while True:
            try:
                linea = q.get(timeout=30)
                if linea is None:
                    break
                yield "data: " + linea.rstrip() + "\n\n"
            except queue.Empty:
                yield ": keepalive\n\n"

    return Response(generate(), mimetype="text/event-stream")


@app.route("/cancelar/<job_id>", methods=["POST"])
def cancelar(job_id):
    with lock:
        proc = active_processes.get(job_id)
    if proc:
        try:
            proc.terminate()
            return jsonify({"ok": True})
        except Exception as e:
            return jsonify({"ok": False, "error": str(e)}), 500
    return jsonify({"ok": False, "error": "No hay proceso activo"}), 404


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)
SERVER_EOF

# ---------- index.html ----------
cat > "$WORKDIR/templates/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Abyss Downloader</title>
<style>
*{box-sizing:border-box}
body{font-family:sans-serif;padding:16px;max-width:600px;margin:auto;background:#f5f5f5}
h1{font-size:1.2rem;margin-bottom:16px}
label{display:block;margin:10px 0 4px;font-weight:bold;font-size:.9rem}
input,select,textarea{width:100%;padding:8px;border:1px solid #ccc;border-radius:4px;font-size:.95rem}
textarea{height:80px;resize:vertical}
.row{display:flex;gap:8px;margin:10px 0}
.row>div{flex:1}
button{padding:10px 16px;font-size:1rem;cursor:pointer;border:none;border-radius:4px}
.btn-descargar{background:#2e7d32;color:#fff}
.btn-descargar:disabled{background:#9e9e9e}
.btn-cancelar{background:#c62828;color:#fff}
.btn-cancelar:disabled{background:#9e9e9e}
#log{background:#1e1e1e;color:#0f0;padding:12px;border-radius:6px;height:300px;overflow-y:auto;font-family:monospace;font-size:.85rem;white-space:pre-wrap;margin-top:12px}
.msg{margin:8px 0;padding:8px;border-radius:4px;display:none}
.ok{background:#e8f5e9;color:#2e7d32;border:1px solid #c8e6c9}
.err{background:#ffebee;color:#c62828;border:1px solid #ffcdd2}
.info{background:#e3f2fd;color:#1565c0;border:1px solid #bbdefb}
</style>
</head>
<body>
<h1>📥 Abyss Downloader</h1>
<div id="msg" class="msg info"></div>
<label>ID o URL del video:</label>
<input type="text" id="entrada" placeholder="https://ejemplo.com/video o ID">
<label>Resolución:</label>
<select id="resolucion">
<option value="ninguna">ninguna</option>
<option value="h">h (alta)</option>
<option value="m">m (media)</option>
<option value="l">l (baja)</option>
</select>
<div class="row">
<div><label>Carpeta de salida:</label><input type="text" id="carpeta" value="/sdcard/Download"></div>
<div><label>Nombre de archivo (opcional):</label><input type="text" id="nombre" placeholder="video.mp4"></div>
</div>
<label>Conexiones (1-10):</label>
<input type="number" id="conexiones" value="4" min="1" max="10">
<label>Headers HTTP (uno por línea, opcional):</label>
<textarea id="headers" placeholder="Authorization: Bearer xxx&#10;User-Agent: Mozilla/5.0"></textarea>
<label><input type="checkbox" id="verbose"> Modo verbose</label>
<div style="margin-top:16px">
<button class="btn-descargar" id="btnDescargar" onclick="descargar()">Descargar</button>
<button class="btn-cancelar" id="btnCancel" disabled onclick="cancelar()">Cancel</button>
</div>
<div id="log"></div>
<script>
let currentJobId=null,eventSource=null;
function show(m,t='info'){const e=document.getElementById('msg');e.textContent=m;e.className='msg '+t;e.style.display='block'}
function appendLog(t){const l=document.getElementById('log');l.textContent+=t+"\n";l.scrollTop=l.scrollHeight}
async function descargar(){
const entrada=document.getElementById('entrada').value.trim();
if(!entrada){show("Ingresa el ID o URL del video.",'err');return}
const payload={entrada:entrada,resolucion:document.getElementById('resolucion').value,carpeta:document.getElementById('carpeta').value,nombre:document.getElementById('nombre').value,conexiones:parseInt(document.getElementById('conexiones').value)||4,verbose:document.getElementById('verbose').checked,headers:document.getElementById('headers').value.split("\n")};
try{
const res=await fetch('/descargar',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
const data=await res.json();
if(data.error){show(data.error,'err');return}
currentJobId=data.job_id;
document.getElementById('btnDescargar').disabled=true;
document.getElementById('btnCancel').disabled=false;
document.getElementById('log').textContent='';
show("Descarga iniciada...",'ok');
eventSource=new EventSource('/logs/'+currentJobId);
eventSource.onmessage=function(e){
if(e.data.startsWith('[END]:')){appendLog("\n✅ Proceso terminado con código "+e.data.split(':')[1]);finalizar()}
else if(e.data.startsWith('[ERROR]:')){appendLog("\n❌ Error: "+e.data.split(':')[1]);finalizar()}
else{appendLog(e.data)}};
eventSource.onerror=finalizar;
}catch(err){show("Error al conectar con el servidor: "+err.message,'err')}
}
async function cancelar(){
if(!currentJobId)return;
try{await fetch('/cancelar/'+currentJobId,{method:'POST'});appendLog("\n>>> Cancelando descarga...")}catch(err){show("No se pudo cancelar: "+err.message,'err')}
finalizar();
}
function finalizar(){
document.getElementById('btnDescargar').disabled=false;
document.getElementById('btnCancel').disabled=true;
if(eventSource){eventSource.close();eventSource=null}
currentJobId=null;
}
</script>
</body>
</html>
HTML_EOF

echo "   ✅ Archivos creados"

# ---------- Detener servidor anterior ----------
pkill -f "python server.py" 2>/dev/null
sleep 1

# ---------- Arrancar ----------
cd "$WORKDIR"
nohup python server.py > server.log 2>&1 &
sleep 8

# ---------- Obtener IP automáticamente ----------
IP=""
# Método 1: ifconfig
if [ -z "$IP" ] && command -v ifconfig >/dev/null 2>&1; then
    IP=$(ifconfig 2>/dev/null | awk '/wlan0|swlan0|wlan|eth0/ {getline; if($1=="inet") print $2; exit}')
fi
# Método 2: ip addr
if [ -z "$IP" ] && command -v ip >/dev/null 2>&1; then
    IP=$(ip addr 2>/dev/null | awk '/wlan|swlan|eth0/ {getline; if($1=="inet") print $2; exit}' | cut -d/ -f1)
fi
# Método 3: hostname -I
if [ -z "$IP" ]; then
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
# Método 4: proc net fib_trie
if [ -z "$IP" ]; then
    IP=$(grep -E '^[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /proc/net/fib_trie 2>/dev/null | head -1 | awk '{print $1}')
fi

echo ""
echo "============================================"
echo "🚀 ¡Abyss Downloader LISTO!"
echo "============================================"
if [ -n "$IP" ]; then
    echo "🌐 URL: http://$IP:5000"
    echo ""
    echo "📱 Paso final: Abrí el navegador del celular y escribí:"
    echo "               http://$IP:5000"
    echo ""
    echo "💡 Intento de abrir navegador automáticamente..."
    am start -a android.intent.action.VIEW -d "http://$IP:5000" >/dev/null 2>&1 && echo "   ✅ Navegador abierto" || echo "   ⚠️  No se pudo abrir automáticamente, abrí el navegador manualmente."
else
    echo "⚠️  No se detectó la IP automáticamente."
    echo "   Ejecutá este comando en Termux para verla:"
    echo "   hostname -I"
fi
echo ""
echo "📂 Videos en: /sdcard/Download"
echo "📋 Log del servidor: ~/abyss_server/server.log"
echo ""
echo "⚠️  Dejá Termux abierto mientras uses la app."
echo "============================================"
