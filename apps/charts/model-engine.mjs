// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { FBXLoader } from "three/addons/loaders/FBXLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";

const canvas = document.getElementById("model");
const status = document.getElementById("status");
const reset = document.getElementById("reset");
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(45, 1, 0.001, 100000);
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: "low-power" });
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
const controls = new OrbitControls(camera, canvas);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.screenSpacePanning = true;
scene.add(new THREE.HemisphereLight(0xffffff, 0x7777aa, 2.2));
const key = new THREE.DirectionalLight(0xffffff, 2.4);
key.position.set(3, 6, 8);
scene.add(key);
let model = null;
let active = true;
let initialPosition = null;
let initialTarget = null;
let renderPending = false;

function requestRender() {
    if (!active || renderPending) return;
    renderPending = true;
    requestAnimationFrame(() => {
        renderPending = false;
        if (!active) return;
        // Damping emits another change event until the orbit settles.
        controls.update();
        renderer.render(scene, camera);
    });
}
controls.addEventListener("change", requestRender);

reset.addEventListener("click", () => {
    if (!initialPosition || !initialTarget) return;
    camera.position.copy(initialPosition);
    controls.target.copy(initialTarget);
    controls.update();
});

function resize() {
    const width = Math.max(1, canvas.clientWidth);
    const height = Math.max(1, canvas.clientHeight);
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    requestRender();
}
new ResizeObserver(resize).observe(canvas);
resize();

function decode(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

async function parse(bytes, extension) {
    const buffer = bytes.buffer;
    switch (extension) {
        case "glb":
        case "gltf": {
            // External texture/buffer URLs are blocked by the document CSP.
            const result = await new GLTFLoader().parseAsync(buffer, "");
            return result.scene;
        }
        case "fbx": return new FBXLoader().parse(buffer, "");
        case "obj": return new OBJLoader().parse(new TextDecoder().decode(bytes));
        case "stl": return new THREE.Mesh(new STLLoader().parse(buffer), new THREE.MeshStandardMaterial({ color: 0xa68cff, side: THREE.DoubleSide }));
        case "ply": {
            const geometry = new PLYLoader().parse(buffer);
            const material = new THREE.MeshStandardMaterial({ color: 0xa68cff, side: THREE.DoubleSide, vertexColors: geometry.hasAttribute("color") });
            return new THREE.Mesh(geometry, material);
        }
        default: throw new Error("This model format needs an engine export");
    }
}

function frame(object) {
    let vertices = 0;
    object.traverse((node) => {
        if (node.geometry?.getAttribute) vertices += node.geometry.getAttribute("position")?.count || 0;
    });
    if (vertices > 2_000_000) throw new Error("The model is too detailed to preview");
    const bounds = new THREE.Box3().setFromObject(object);
    if (bounds.isEmpty()) throw new Error("The model contains no visible geometry");
    const center = bounds.getCenter(new THREE.Vector3());
    const size = bounds.getSize(new THREE.Vector3());
    const diameter = Math.max(size.x, size.y, size.z, 0.01);
    if (![center.x, center.y, center.z, diameter].every(Number.isFinite)) throw new Error("The model has invalid geometry");
    controls.target.copy(center);
    const distance = diameter / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2))) * 1.4;
    camera.position.copy(center).add(new THREE.Vector3(distance * 0.6, distance * 0.4, distance));
    camera.near = Math.max(0.001, diameter / 1000);
    camera.far = Math.max(100, diameter * 100);
    camera.updateProjectionMatrix();
    controls.minDistance = diameter * 0.05;
    controls.maxDistance = diameter * 30;
    controls.update();
    initialPosition = camera.position.clone();
    initialTarget = controls.target.clone();
}

export async function load(base64, extension, background) {
    status.textContent = "Loading model…";
    status.hidden = false;
    reset.hidden = true;
    try {
        if (base64.length > 17 * 1024 * 1024) throw new Error("The model is too large to preview");
        scene.background = new THREE.Color(background);
        renderer.setClearColor(background);
        const next = await parse(decode(base64), extension.toLowerCase());
        if (model) scene.remove(model);
        model = next;
        scene.add(model);
        frame(model);
        requestRender();
        status.hidden = true;
        reset.hidden = false;
        return true;
    } catch (error) {
        status.textContent = error?.message || "The model could not be previewed";
        return false;
    }
}

export function dispose() {
    active = false;
    controls.dispose();
    renderer.dispose();
}
