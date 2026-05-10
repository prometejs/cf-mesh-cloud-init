# seed-server.py — sketch, not production code
from flask import Flask, abort, Response
import re, hvac, jinja2

app = Flask(__name__)
vault = hvac.Client(url="https://vault.example.com:8200")
vault.auth.approle.login(
    role_id=os.environ["PROVISIONER_ROLE_ID"],
    secret_id=os.environ["PROVISIONER_SECRET_ID"],
)

@app.route("/seed/<mac>/user-data")
def user_data(mac):
    # Validate MAC format
    if not re.match(r"^([0-9a-f]{2}-){5}[0-9a-f]{2}$", mac):
        abort(400)
    
    # Optional: check MAC against an allow-list
    machine = lookup_inventory(mac)  # returns None if unknown
    if machine is None:
        abort(404)
    
    # Ask Vault to wrap a secret-id for this machine's role
    wrap_response = vault.write(
        f"auth/approle/role/{machine.role}/secret-id",
        wrap_ttl="5m",
    )
    wrapping_token = wrap_response["wrap_info"]["token"]
    
    # Render the user-data template
    template = jinja2.Template(open("user-data.j2").read())
    rendered = template.render(
        hostname=machine.hostname,
        role=machine.role,
        wrapping_token=wrapping_token,
        role_id=machine.role_id,
    )
    
    return Response(rendered, mimetype="text/plain")

@app.route("/seed/<mac>/meta-data")
def meta_data(mac):
    machine = lookup_inventory(mac)
    if machine is None:
        abort(404)
    return f"instance-id: {machine.hostname}\nlocal-hostname: {machine.hostname}\n"

# add url for that returns seed secret for testing, in production this would be protected and not exposed over HTTP
@app.route("/seed/<mac>/secret")
def secret(mac):
    machine = lookup_inventory(mac)
    if machine is None:
        abort(404)
    secret_response = vault.read(f"secret/data/cloudflare/connector/{machine.role}")
    secret_token = secret_response["data"]["data"]["token"]
    return {'warp_orchestration_token': secret_token}