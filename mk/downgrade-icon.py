# downgrade-icon.py <icon.json> <output>: an Icon Composer document's icon.json as Xcode 26's actool takes it. Xcode 27
# reads "features" and a string specular (outside/inside/...); Xcode 26's actool crashes on "features" and only accepts
# a boolean specular.
import json, sys

source_path, output_path = sys.argv[1], sys.argv[2]
with open(source_path) as source_file:
    document = json.load(source_file)
document.pop("features", None)

def walk(node):
    if isinstance(node, dict):
        specular = node.get("specular")
        if isinstance(specular, str):
            node["specular"] = specular not in ("none", "off", "false")
        for child in node.values():
            walk(child)
    elif isinstance(node, list):
        for child in node:
            walk(child)

walk(document)
with open(output_path, "w") as output_file:
    json.dump(document, output_file, indent=2)
    output_file.write("\n")
