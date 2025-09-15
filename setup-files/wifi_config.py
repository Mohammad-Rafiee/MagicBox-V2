import subprocess
import time
from fastapi import FastAPI, Request, Form, status
from fastapi.templating import Jinja2Templates
from fastapi.responses import RedirectResponse, HTMLResponse

app = FastAPI()
templates = Jinja2Templates(directory="templates")

NETPLAN_PATH = "/etc/netplan/50-cloud-init.yaml"
MAX_CHECKS = 5
TEST_TARGET = "8.8.8.8"

def is_connected():
    try:
        result = subprocess.run(["ping", "-c", "1", "-W", "2", TEST_TARGET], capture_output=True, timeout=3)
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False

@app.get("/", response_class=HTMLResponse)
async def root(request: Request, msg: str = None, force: bool = False):
    if not force and is_connected():
        return templates.TemplateResponse("connected.html", {"request": request})
    return templates.TemplateResponse("index.html", {"request": request, "error_message": msg})

@app.post("/configure")
async def configure_wifi(request: Request, ssid: str = Form(...), password: str = Form(...)):
    config = f'''network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses: []
      optional: false
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
            return templates.TemplateResponse("connected.html", {"request": request})
        return RedirectResponse("/?msg=Connection+failed", status_code=status.HTTP_303_SEE_OTHER)

    except Exception as e:
        return RedirectResponse(f"/?msg=Error%3A+{str(e)}", status_code=status.HTTP_303_SEE_OTHER)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)