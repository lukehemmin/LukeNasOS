from flask import Flask, render_template, jsonify
import psutil
import platform

app = Flask(__name__)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/status')
def status():
    cpu_percent = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    
    return jsonify({
        'system': platform.system(),
        'release': platform.release(),
        'cpu_percent': cpu_percent,
        'memory_percent': memory.percent,
        'disk_percent': disk.percent,
        'disk_free': f"{disk.free / (1024**3):.2f} GB",
        'disk_total': f"{disk.total / (1024**3):.2f} GB"
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=True)
