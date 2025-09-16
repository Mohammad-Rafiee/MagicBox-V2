import subprocess
import time
from fastapi import FastAPI, Request, Form, status, BackgroundTasks
from fastapi.templating import Jinja2Templates
from fastapi.responses import RedirectResponse, HTMLResponse

app = FastAPI()
templates = Jinja2Templates(directory="templates")

NETPLAN_PATH = "/etc/netplan/50-cloud-init.yaml"
MAX_CHECKS = 5
TEST_TARGET = "8.8.8.8"
AVAHI_SERVICE_PATH = "/etc/avahi/services/wifi-config.service"

def is_connected():
    try:
        result = subprocess.run(["ping", "-c", "1", "-W", "2", TEST_TARGET], capture_output=True, timeout=3)
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False

def get_wlan_ip():
    try:
        result = subprocess.run(["ip", "-4", "addr", "show", "wlan0"], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if "inet " in line:
                return line.strip().split()[1].split('/')[0]
    except Exception:
        pass
    return "unknown"  # Fallback if unable to fetch


def update_netplan(ssid: str, password: str):
    time.sleep(10)
    new_config = f'''network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses: []
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "{ssid}":
          password: "{password}"
'''
    try:
        with open(NETPLAN_PATH, "w") as f:
            f.write(new_config)
        apply_result = subprocess.run(["netplan", "apply"], capture_output=True, text=True, timeout=15)
        if apply_result.returncode != 0:
            # You can add logging here if needed
            pass
    except Exception:
        # Silent failure or add logging
        pass


@app.get("/", response_class=HTMLResponse)
async def root(request: Request, msg: str = None, force: bool = False):
    if not force and is_connected():
        wlan_ip = get_wlan_ip()
        return templates.TemplateResponse("connected.html", {"request": request, "wlan_ip": wlan_ip})
    return templates.TemplateResponse("index.html", {"request": request, "error_message": msg})

@app.post("/configure")
async def configure_wifi(
    request: Request,
    ssid: str = Form(...),
    password: str = Form(...),
    background_tasks: BackgroundTasks = None
):
    config = f'''network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses: [192.168.2.1/24]
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "{ssid}":
          password: "{password}"
'''
    try:
        with open(NETPLAN_PATH, "w") as f:
            f.write(config)
        apply_result = subprocess.run(["netplan", "apply"], capture_output=True, text=True, timeout=15)
        if apply_result.returncode != 0:
            raise Exception(f"Netplan failed: {apply_result.stderr}")

        connected = False
        for _ in range(MAX_CHECKS):
            time.sleep(5)
            if is_connected():
                connected = True
                break

        if connected:
            wlan_ip = get_wlan_ip()
            background_tasks.add_task(update_netplan, ssid, password)
            return templates.TemplateResponse("connected.html", {"request": request, "wlan_ip": wlan_ip})
        return RedirectResponse("/?msg=Connection+failed", status_code=status.HTTP_303_SEE_OTHER)
    except Exception as e:
        return RedirectResponse(f"/?msg=Error%3A+{str(e)}", status_code=status.HTTP_303_SEE_OTHER)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)