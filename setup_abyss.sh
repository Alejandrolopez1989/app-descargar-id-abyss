#!/data/data/com.termux/files/usr/bin/bash
# ==========================================================
#  Abyss Downloader - instalador automatico (v2.2.0)
#  1. Solicita permiso de almacenamiento (solo la primera vez)
#  2. Instala dependencias (python, openjdk-21, flask, net-tools, procps)
#  3. Copia/Descarga el JAR a ~/abyss_server/
#  4. Crea server.py y index.html (con-botones Detener/Cancel)
#  5. Mata cualquier servidor anterior y arranca el nuevo en background
#  6. Detecta la IP y abre el navegador automaticamente
# ==========================================================

# ---------- 0. Permiso de almacenamiento (solo la primera vez) ----------
echo "Verificando permiso de almacenamiento..."
if [ ! -d "$HOME/storage" ]; then
    echo "   Primera vez: se va a abrir el dialogo de Android. Aceptalo."
    termux-setup-storage >/dev/null 2>&1
    sleep 4
fi
if [ -d "$HOME/storage" ]; then
    echo "   OK - permiso de almacenamiento activo"
else
    echo "   AVISO - si no puedes guardar archivos, ejecuta: termux-setup-storage"
fi

# ---------- 1. Dependencias ----------
echo "Instalando dependencias (python, openjdk-21, flask)..."
pkg update -y >/dev/null 2>&1
pkg install -y python openjdk-21 net-tools procps >/dev/null 2>&1
python -c "import flask" >/dev/null 2>&1 || pip install -q flask >/dev/null 2>&1 || pip install -q --break-system-packages flask >/dev/null 2>&1
echo "   OK - dependencias instaladas"

# ---------- 2. Variables ----------
WORKDIR="$HOME/abyss_server"
JAR_URL="https://github.com/Alejandrolopez1989/app-descargar-id-abyss/releases/latest/download/abyss-dl.jar"

# ---------- 3. Preparar carpetas ----------
mkdir -p "$WORKDIR/templates"
cd "$WORKDIR"

# ---------- 4. Copiar/Descargar el JAR ----------
if [ -f "$WORKDIR/abyss-dl.jar" ]; then
    echo "OK - el JAR ya esta en $WORKDIR"
else
    if [ -f /sdcard/Download/abyss-dl.jar ]; then
        cp /sdcard/Download/abyss-dl.jar "$WORKDIR/abyss-dl.jar"
        echo "OK - JAR copiado desde /sdcard/Download"
    else
        echo "Descargando JAR desde GitHub Releases..."
        curl -fLs "$JAR_URL" -o "$WORKDIR/abyss-dl.jar" || { echo "ERROR: no se pudo descargar el JAR"; exit 1; }
        echo "   OK - JAR descargado"
    fi
fi

# ---------- 5. Crear server.py ----------
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


@app.route("/parar", methods=["GET", "POST"])
def parar():
    """Detiene por completo el servidor web."""
    def killer():
        import time
        time.sleep(0.5)
        os._exit(0)

    threading.Thread(target=killer, daemon=True).start()
    return jsonify({"ok": True, "msg": "Servidor detenido"})


@app.route("/estado")
def estado():
    return jsonify({"ok": True, "servidor": "activo"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)
SERVER_EOF

# ---------- 6. Crear index.html ----------
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
        button{padding:10px 16px;font-size:1rem;border:none;border-radius:4px;cursor:pointer}
        .btn-descargar{background:#2e7d32;color:#fff}
        .btn-descargar:disabled{background:#9e9e9e}
        .btn-cancelar{background:#c62828;color:#fff}
        .btn-cancelar:disabled{background:#9e9e9e}
        .btn-stop{background:#455a64;color:#fff}
        #log{background:#1e1e1e;color:#0f0;padding:12px;border-radius:6px;height:300px;overflow-y:auto;font-family:monospace;font-size:.85rem;white-space:pre-wrap;margin-top:12px}
        .msg{margin:8px 0;padding:8px;border-radius:4px;display:none}
        .ok{background:#e8f5e9;color:#2e7d32;border:1px solid #c8e6c9}
        .err{background:#ffebee;color:#c62828;border:1px solid #ffcdd2}
        .info{background:#e3f2fd;color:#1565c0;border:1px solid #bbdefb}
        #overlay{display:none;position:fixed;inset:0;background:#263238;color:#fff;z-index:9999;justify-content:center;align-items:center;text-align:center;padding:30px}
        #overlay h2{font-size:1.4rem;margin-bottom:12px}
        #overlay p{opacity:.8;line-height:1.6}
    </style>
</head>
<body>
<h1>Abyss Downloader</h1>

<div id="msg" class="msg info"></div>

<label>ID o URL del video:</label>
<input type="text" id="entrada" placeholder="https://ejemplo.com/video o ID">

<label>Resolucion:</label>
<select id="resolucion">
    <option value="ninguna">ninguna</option>
    <option value="h">h (alta)</option>
    <option value="m">m (media)</option>
    <option value="l">l (baja)</option>
</select>

<div class="row">
    <div>
        <label>Carpeta de salida:</label>
        <input type="text" id="carpeta" value="/sdcard/Download">
    </div>
    <div>
        <label>Nombre de archivo (opcional):</label>
        <input type="text" id="nombre" placeholder="video.mp4">
    </div>
</div>

<label>Conexiones (1-10):</label>
<input type="number" id="conexiones" value="4" min="1" max="10">

<label>Headers HTTP (uno por linea, opcional):</label>
<textarea id="headers" placeholder="Authorization: Bearer xxx&#10;User-Agent: Mozilla/5.0"></textarea>

<label><input type="checkbox" id="verbose"> Modo verbose</label>

<div style="margin-top:16px;">
    <button class="btn-descargar" id="btnDescargar" onclick="descargar()">Descargar</button>
    <button class="btn-cancelar" id="btnCancel" disabled onclick="cancelar()">Cancel</button>
    <button class="btn-stop" id="btnStop" onclick="stopServer()">Detener servidor</button>
</div>

<div id="log"></div>

<div id="overlay">
    <div>
        <h2>Servidor detenido</h2>
        <p>El servidor de descargas fue apagado.<br>Para volver a iniciar, vuelve a Termux y ejecuta:<br><br><code>~/setup_abyss.sh</code></p>
    </div>
</div>

<script>
    let currentJobId = null;
    let eventSource = null;

    function show(msg, t) {
        const el = document.getElementById('msg');
        el.textContent = msg;
        el.className = 'msg ' + (t || 'info');
        el.style.display = 'block';
    }

    function appendLog(t) {
        const log = document.getElementById('log');
        log.textContent += t + "\n";
        log.scrollTop = log.scrollHeight;
    }

    async function descargar() {
        const entrada = document.getElementById('entrada').value.trim();
        if (!entrada) { show('Ingresa el ID o URL del video.', 'err'); return; }

        const headersRaw = document.getElementById('headers').value.split("\n");
        const payload = {
            entrada: entrada,
            resolucion: document.getElementById('resolucion').value,
            carpeta: document.getElementById('carpeta').value,
            nombre: document.getElementById('nombre').value,
            conexiones: parseInt(document.getElementById('conexiones').value) || 4,
            verbose: document.getElementById('verbose').checked,
            headers: headersRaw
        };

        try {
            const res = await fetch('/descargar', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            const data = await res.json();
            if (data.error) { show(data.error, 'err'); return; }

            currentJobId = data.job_id;
            document.getElementById('btnDescargar').disabled = true;
            document.getElementById('btnCancel').disabled = false;
            document.getElementById('log').textContent = '';
            show('Descarga iniciada...', 'ok');

            eventSource = new EventSource('/logs/' + currentJobId);
            eventSource.onmessage = function (e) {
                if (e.data.startsWith('[END]:')) {
                    appendLog("\n[OK] Proceso terminado con codigo " + e.data.split(':')[1]);
                    finalizar();
                } else if (e.data.startsWith('[ERROR]:')) {
                    appendLog("\n[ERROR] " + e.data.split(':')[1]);
                    finalizar();
                } else {
                    appendLog(e.data);
                }
            };
            eventSource.onerror = function () { finalizar(); };
        } catch (err) {
            show('Error al conectar con el servidor: ' + err.message, 'err');
        }
    }

    async function cancelar() {
        if (!currentJobId) return;
        try {
            await fetch('/cancelar/' + currentJobId, { method: 'POST' });
            appendLog("\nCancelando descarga...");
        } catch (err) {
            show('No se pudo cancelar: ' + err.message, 'err');
        }
        finalizar();
    }

    async function stopServer() {
        if (!confirm('Seguro que quieres detener el servidor? La pagina dejara de funcionar.')) return;
        try {
            const res = await fetch('/parar');
            const data = await res.json();
            show('Servidor detenido.', 'info');
            document.getElementById('overlay').style.display = 'flex';
            finalizar();
        } catch (err) {
            show('Error al detener: ' + err.message, 'err');
        }
    }

    function finalizar() {
        document.getElementById('btnDescargar').disabled = false;
        document.getElementById('btnCancel').disabled = true;
        if (eventSource) { eventSource.close(); eventSource = null; }
        currentJobId = null;
    }
</script>
</body>
</html>
HTML_EOF

echo "OK - archivos creados."

# ---------- 7. Crear el script para parar desde la terminal ----------
cat > "$HOME/parar_abyss.sh" << 'STOP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -f "python server.py" 2>/dev/null
echo "Servidor Abyss Downloader detenido."
STOP_EOF
chmod +x "$HOME/parar_abyss.sh"

# ---------- 8. Detener cualquier servidor anterior ----------
echo "Deteniendo servidor anterior (si habia uno)..."
pkill -f "python server.py" 2>/dev/null
sleep 1

# ---------- 9. Iniciar el servidor ----------
echo "Iniciando servidor en segundo plano..."
cd "$WORKDIR"
nohup python server.py > server.log 2>&1 &
SERVER_PID=$!
sleep 4

# Verificar que arranco correctamente
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: el servidor no arranco. Log:"
    tail -n 20 "$WORKDIR/server.log"
    exit 1
fi

# ---------- 10. Detectar la IP (varios metodos) ----------
IP=""

# Metodo 1: ip addr
if command -v ip >/dev/null 2>&1; then
    IP=$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/ {split($2,a,"/"); print a[1]; exit}')
fi

# Metodo 2: ifconfig
if [ -z "$IP" ] && command -v ifconfig >/dev/null 2>&1; then
    IP=$(ifconfig 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/ {print $2; exit}')
fi

# Metodo 3: /proc/net/fib_trie
if [ -z "$IP" ]; then
    IP=$(awk '/32 host/ {print $2}' /proc/net/fib_trie 2>/dev/null | grep -v '^127\.' | head -1)
fi

# Metodo 4: hostname -i
if [ -z "$IP" ] && command -v hostname >/dev/null 2>&1; then
    IP=$(hostname -i 2>/dev/null | awk '{print $1}')
fi

[ -z "$IP" ] && IP="127.0.0.1"

# ---------- 11. Abrir el navegador automaticamente ----------
echo "Abriendo el navegador..."
am start -a android.intent.action.VIEW -d "http://$IP:5000" >/dev/null 2>&1

echo ""
echo "============================================"
echo " SERVIDOR ABYSS DOWNLOADER LISTO (PID $SERVER_PID)"
echo "============================================"
echo " URL: http://$IP:5000"
echo "============================================"
echo " Detener desde la web  ->oboton 'Detener servidor'"
echo " Detener desde terminal -> ~/parar_abyss.sh"
echo " Log completo           -> $WORKDIR/server.log"
echo "============================================"
