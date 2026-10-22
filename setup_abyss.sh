cat > ~/setup_abyss.sh << 'END_SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# ==========================================================
#  Abyss Downloader – instalador automático (v2.0.0)
# ==========================================================
#  1️⃣  Instala dependencias (python, openjdk‑21, flask)
#  2️⃣  Copia el JAR (si está en /sdcard/Download)
#  3. Crea server.py y index.html (con botón “Detener servidor”)
#  4. Lanza el servidor con nohup y muestra la URL
#  5. (Opcional) abre el navegador automáticamente
# ==========================================================

# ---------- 1.  Asegurarse de que el storage está listo ----------
# El usuario debe ejecutar "termux-setup-storage" una sola vez.
# Si no lo ha hecho, el script avisará y seguirá de todos modos.
if [ ! -d "$HOME/storage" ]; then
    echo "⚠️  Aviso: parece que el storage no está configurado."
    echo "   Ejecuta:  termux-setup-storage   (solo la primera vez)"
    echo "   y vuelve a ejecutar este script."
fi

# ---------- 2.  Instalar dependencias ----------
echo "🔧 Instalando dependencias (python, openjdk-21, flask)..."
pkg update -y >/dev/null 2>&1
pkg install -y python openjdk-21 net-tools >/dev/null 2>&1
pip install -q flask >/dev/null 2>&1
echo "   ✅ Dependencias instaladas"

# ---------- 3.  Preparar carpetas ----------
WORKDIR="$HOME/abyss_server"
mkdir -p "$WORKDIR/templates"
cd "$WORKDIR"

# ---------- 4.  Copiar el JAR ----------
JAR_PATH="$WORKDIR/abyss-dl.jar"
if [ -f "$WORKDIR/abyss-dl.jar" ]; then
    echo "✅ JAR ya está en $WORKDIR"
else
    if [ -f /sdcard/Download/abyss-dl.jar ]; then
        cp /sdcard/Download/abyss-dl.jar "$WORKDIR/abyss-dl.jar"
        echo "✅ JAR copiado desde /sdcard/Download"
    else
        echo "⬇️  Descargando JAR desde GitHub..."
        curl -fLs "$JAR_URL" -o "$WORKDIR/abyss-dl.jar" || { echo "❌ No se pudo descargar el JAR"; exit 1; }
        echo "   ✅ JAR descargado"
    fi
fi

# ---------- 5.  Crear server.py ----------
cat > "$WORKDIR/server.py" <<'SERVER_EOF'
import os
import subprocess
import threading
import uuid
import queue
from flask import Flask, render_template, request, jsonify, Response

app = Flask(__name__)

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


@app.route("/stop")
def stop():
    # Mata el proceso Flask (y por tanto el servidor)
    os._exit(0)


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
        * { box-sizing:border-box; }
        body { font-family:sans-serif; padding:16px; max-width:600px; margin:auto; background:#f5f5f5; }
        h1 { font-size:1.2rem; margin-bottom:16px; }
        label { display:block; margin:10px 0 4px; font-weight:bold; font-size:.9rem; }
        input, select, textarea { width:100%; padding:8px; border:1px solid #ccc; border-radius:4px; font-size:.95rem; }
        textarea { height:80px; resize:vertical; }
        .row { display:flex; gap:8px; margin:10px 0; }
        .row > div { flex:1; }
        button { padding:10px 16px; font-size:1rem; cursor:pointer; border:none; border-radius:4px; }
        .btn-descargar { background:#2e7d32; color:#fff; }
        .btn-descargar:disabled { background:#9e9e9e; }
        .btn-cancelar { background:#c62828; color:#fff; }
        .btn-cancelar:disabled { background:#9e9e9e; }
        .btn-stop { background:#d9534f; color:#fff; }
        .btn-cancelar:disabled { background:#9e9e9e; }
        #log { background:#1e1e1e; color:#0f0; padding:12px; border-radius:6px; height:300px; overflow-y:auto; 
               font-family:monospace; font-size:.85rem; white-space:pre-wrap; margin-top:12px; }
        .msg { margin:8px 0; padding:8px; border-radius:4px; display:none; }
        .ok { background:#e8f5e9; color:#2e7d32; border:1px solid #c8e6c9; }
        .err { background:#ffebee; color:#c62828; border:1px solid #ffcdd2; }
        .info { background:#e3f2fd; color:#1565c0; border:1px solid #bbdefb; }
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

<label>Headers HTTP (uno por línea, opcional):</label>
<textarea id="headers" placeholder="Authorization: Bearer xxx&#10;User-Agent: Mozilla/5.0"></textarea>

<label>
    <input type="checkbox" id="verbose"> Modo verbose
</label>

<div style="margin-top:16px;">
    <button class="btn-descargar" id="btnDescargar" onclick="descargar()">Descargar</button>
    <button class="btn-cancelar" id="btnCancel" disabled onclick="cancelar()">Cancel</button>
    <button class="btn-stop" id="btnStop" onclick="stopServer()">Detener servidor</button>
</div>

<div id="log"></div>

<script>
    let currentJobId = null;
    let eventSource = null;

    function show(msg, type = 'info') {
        const el = document.getElementById('msg');
        el.textContent = msg;
        el.className = 'msg ' + type;
        el.style.display = 'block';
    }

    function appendLog(text) {
        const log = document.getElementById('log');
        log.textContent += text + "\n";
        log.scrollTop = log.scrollHeight;
    }

    async function descargar() {
        const entrada = document.getElementById('entrada').value.trim();
        if (!entrada) {
            show("Ingresa el ID o URL del video.", 'err');
            return;
        }

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
            };
            const data = await res.json();

            if (data.error) {
                show(data.error, 'err');
                return;
            }

            currentJobId = data.job_id;
            document.getElementById('btnDescargar').disabled = true;
            document.getElementById('btnCancel').disabled = false;
            document.getElementById('log').textContent = '';
            show("Descarga iniciada...", 'ok');

            eventSource = new EventSource('/logs/' + currentJobId);
            eventSource.onmessage = function (e) {
                if (e.data.startsWith('[END]:')) {
                    const code = e.data.split(':')[1];
                    appendLog("\n✅ Proceso terminado con código " + code);
                    finalizar();
                } else if (e.data.startsWith('[ERROR]:')) {
                    const err = e.data.split(':')[1];
                    appendLog("\n❌ Error: " + err);
                    finalizar();
                } else {
                    appendLog(e.data);
                }
            };
            eventSource.onerror = function () {
                finalizar();
            };
        } catch (err) {
            show("Error al conectar con el servidor: " + err.message, 'err');
        }
}

async function cancelar() {
    if (!currentJobId) return;
    try {
        await fetch('/cancelar/' + currentJobId, { method: 'POST' });
        appendLog("\n>>> Cancelando descarga...");
    } catch (err) {
        show("No se pudo cancelar: " + err.message, 'err');
    }
    finalizar();
}

function finalizar() {
    document.getElementById('btnDescargar').disabled = false;
    document.getElementById('btnCancel').disabled = true;
    if (eventSource) {
        eventSource.close();
        eventSource = null;
    }
    currentJobId = null;
}

// ---------- Botón para detener el servidor ----------
async function stopServer() {
    if (!currentJobId) {
        show("Primero descarga algo para poder detener el servidor.", 'err');
        return;
    }
    if (confirm("¿Seguro que quieres detener el servidor?")) {
        await fetch('/stop');
        show("🛑 Servidor detenido.", 'info');
        finalizar();
    }
}

function show(msg, tipo = 'info') {
    const el = document.getElementById('msg');
    el.textContent = msg;
    el.className = 'msg ' + tipo;
    el.style.display = 'block';
}

function appendLog(text) {
    const log = document.getElementById('log');
    log.textContent += text + "\n";
    log.scrollTop = log.scrollHeight;
}

function finalizar() {
    document.getElementById('btnDescargar').disabled = false;
    document.getElementById('btnCancel').disabled = true;
    if (eventSource) {
        eventSource.close();
        eventSource = null;
    }
    currentJobId = null;
}
</script>
</body>
</html>
HTML_EOF

echo "✅  Archivos creados con éxito."

# ---------- Lanzar el servidor ----------
echo "🚀 Iniciando servidor (nohup)..."
nohup python "$WORKDIR/server.py" > "$WORKDIR/server.log" 2>&1 &
sleep 8   # tiempo suficiente para que Flask arranque

# ---------- Obtener la IP del dispositivo ----------
IP=$(ifconfig 2>/dev/null | awk '/wlan0|swlan0/ && /inet/ {print $2; exit}')
if [ -z "$IP" ]; then
    IP=$(hostname -I | awk '{print $1}')
fi

echo ""
echo "============================================"
echo "🚀 Servidor Abyss Downloader está corriendo"
echo "============================================"
echo "🌐 URL: http://$IP:5000"
echo ""
echo "📂 Videos se guardarán en: /sdcard/Download"
echo "📋 Log completo: $WORKDIR/server.log"
echo ""
echo "⚠️  Mantén la terminal de Termux abierta mientras uses la app."
echo "============================================"
END_SCRIPT
