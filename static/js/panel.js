// Panel de calidad del aire: estado, medidor, gráfica con bandas y mapa.

(function () {

    const INTERVALO_MS = 30000;
    const COLOR = { Bueno: "#2E9E5B", Medio: "#D9A514", Malo: "#D64545", viejo: "#9AA5A0" };
    const BANDAS_ICA = [
        { desde: 0,  hasta: 33,  color: "rgba(46,158,91,0.16)" },
        { desde: 33, hasta: 66,  color: "rgba(217,165,20,0.18)" },
        { desde: 66, hasta: 100, color: "rgba(214,69,69,0.16)" },
    ];

    const estado = { ubicacion: "", minutos: 60, variable: "ICA" };
    let grafica = null;
    let mapa = null;
    let capaMapa = null;
    let primeraCargaMapa = true;
    let ubicacionesCargadas = false;

    const $ = (id) => document.getElementById(id);

    // Escapa texto de la base de datos antes de ponerlo en HTML.
    function esc(texto) {
        const d = document.createElement("div");
        d.textContent = texto ?? "";
        return d.innerHTML;
    }

    function formatear(valor) {
        if (valor === null || valor === undefined) return "--";
        if (valor >= 100) return valor.toFixed(0);
        if (valor >= 1)   return valor.toFixed(1);
        return valor.toFixed(3);
    }

    async function pedir(url) {
        const r = await fetch(url);
        if (!r.ok) throw new Error("Error " + r.status + " en " + url);
        return r.json();
    }

    // ---------- Medidor de aguja (SVG) ----------

    function punto(valor, radio) {
        const grados = 180 - valor * 1.8;
        const rad = grados * Math.PI / 180;
        return [120 + radio * Math.cos(rad), 120 - radio * Math.sin(rad)];
    }

    function dibujarArcos() {
        const tramos = [[0, 33, COLOR.Bueno], [33, 66, COLOR.Medio], [66, 100, COLOR.Malo]];
        $("medidorArcos").innerHTML = tramos.map(([a, b, c]) => {
            const [x0, y0] = punto(a, 90);
            const [x1, y1] = punto(b, 90);
            return `<path d="M ${x0} ${y0} A 90 90 0 0 1 ${x1} ${y1}"
                          fill="none" stroke="${c}" stroke-width="20"></path>`;
        }).join("");
    }

    function moverAguja(puntaje) {
        const v = puntaje === null ? 0 : Math.max(0, Math.min(100, puntaje));
        $("medidorAguja").style.transform = `rotate(${v * 1.8}deg)`;
        $("medidorValor").textContent = puntaje === null ? "--" : puntaje.toFixed(0) + " / 100";
    }

    // ---------- Estado actual ----------

    function pintarEstado(datos) {
        const e = datos.estado;

        $("totalLecturas").textContent = datos.total_lecturas ?? "--";
        $("ultimaLectura").textContent = datos.ultima_lectura ?? "--";
        $("ultimaFecha").textContent = datos.ultima_fecha ?? "--";

        if (!e) {
            $("estadoPanel").dataset.nivel = "sin-datos";
            $("estadoNivel").textContent = "Sin datos";
            $("estadoMensaje").textContent = "Todavía no hay lecturas para este lugar.";
            $("estadoValidacion").textContent = "";
            $("tablaGases").innerHTML = '<tr><td colspan="3">--</td></tr>';
            moverAguja(null);
            return;
        }

        $("ultimoVoltaje").textContent = e.voltaje + " V en el pin ADC";
        $("ultimoSensor").textContent = "Sensor " + e.sensor + (e.simulado ? " (simulado)" : "");

        // Si la lectura no es válida o reciente, no se declara una calidad.
        const conNivel = e.valida && e.nivel;
        $("estadoPanel").dataset.nivel = conNivel ? e.nivel : "sin-datos";
        $("estadoNivel").textContent = conNivel ? e.nivel : "Sin lectura válida";
        $("estadoLugar").textContent = e.ubicacion.nombre + " · " + e.ubicacion.tipo;
        $("estadoMensaje").textContent = conNivel
            ? e.mensaje + (e.gas_dominante ? " Gas que más influye: " + e.gas_dominante + "." : "")
            : "No se puede confirmar la calidad del aire con esta lectura.";

        const val = $("estadoValidacion");
        val.textContent = e.motivo_validacion;
        val.classList.toggle("alerta", !e.valida);

        moverAguja(conNivel ? e.puntaje : null);

        $("tablaGases").innerHTML = e.gases.map((g) => {
            const ancho = Math.max(2, Math.min(100, g.puntaje));
            return `<tr>
                <td class="gas-nombre">${esc(g.nombre)}<small>${esc(g.formula)}</small></td>
                <td class="gas-valor">${formatear(g.concentracion)} ${esc(g.unidad)}
                    <div class="barra-gas"><span style="width:${ancho}%;background:${COLOR[g.nivel]}"></span></div>
                </td>
                <td><span class="etiqueta-nivel ${g.nivel}">${g.nivel}</span></td>
            </tr>`;
        }).join("");
    }

    async function cargarEstado() {
        const q = estado.ubicacion ? "?ubicacion=" + encodeURIComponent(estado.ubicacion) : "";
        const datos = await pedir("/api/estadisticas" + q);
        pintarEstado(datos);
    }

    // ---------- Gráfica con bandas de color ----------

    const pluginBandas = {
        id: "bandas",
        beforeDraw(chart, args, opciones) {
            if (!opciones || !opciones.bandas) return;
            const { ctx, chartArea: a, scales: { y } } = chart;
            ctx.save();
            opciones.bandas.forEach((b) => {
                const arriba = y.getPixelForValue(Math.min(b.hasta, y.max));
                const abajo = y.getPixelForValue(Math.max(b.desde, y.min));
                if (abajo > arriba) {
                    ctx.fillStyle = b.color;
                    ctx.fillRect(a.left, arriba, a.right - a.left, abajo - arriba);
                }
            });
            ctx.restore();
        },
    };

    function etiquetaHora(texto) {
        const f = new Date(texto.replace(" ", "T"));
        const hh = String(f.getHours()).padStart(2, "0");
        const mm = String(f.getMinutes()).padStart(2, "0");
        return estado.minutos > 360 ? f.getDate() + "/" + (f.getMonth() + 1) + " " + hh + ":" + mm : hh + ":" + mm;
    }

    function construirChips(catalogo) {
        const cont = $("chipsGas");
        if (cont.dataset.listo) return;
        cont.dataset.listo = "1";

        const opciones = [{ codigo: "ICA", etiqueta: "Índice (0-100)" }].concat(
            catalogo.map((g) => ({ codigo: g.codigo, etiqueta: g.formula }))
        );

        cont.innerHTML = opciones.map((o) =>
            `<button class="chip${o.codigo === estado.variable ? " activo" : ""}" data-var="${esc(o.codigo)}">${esc(o.etiqueta)}</button>`
        ).join("");
    }

    async function cargarSerie() {
        if (!estado.ubicacion) return;

        const datos = await pedir(`/api/serie?ubicacion=${encodeURIComponent(estado.ubicacion)}&minutos=${estado.minutos}`);
        construirChips(datos.catalogo);

        const esICA = estado.variable === "ICA";
        const gas = datos.catalogo.find((g) => g.codigo === estado.variable);
        const valores = esICA ? datos.ica : (datos.gases[estado.variable] || []);

        let bandas, tituloY, maximo;
        if (esICA) {
            bandas = BANDAS_ICA;
            tituloY = "Índice de calidad (0-100)";
            maximo = 100;
        } else {
            const m = gas.umbral_medio, M = gas.umbral_malo;
            bandas = [
                { desde: 0, hasta: m, color: BANDAS_ICA[0].color },
                { desde: m, hasta: M, color: BANDAS_ICA[1].color },
                { desde: M, hasta: Infinity, color: BANDAS_ICA[2].color },
            ];
            tituloY = gas.nombre + " (" + gas.unidad + ")";
            maximo = Math.max(M * 1.25, ...valores.filter((v) => v !== null));
        }

        $("graficaVacia").hidden = datos.etiquetas.length > 0;

        const etiquetas = datos.etiquetas.map(etiquetaHora);

        if (grafica) grafica.destroy();

        grafica = new Chart($("graficaSerie"), {
            type: "line",
            data: {
                labels: etiquetas,
                datasets: [{
                    label: tituloY,
                    data: valores,
                    borderColor: "#10482E",
                    borderWidth: 2,
                    pointRadius: datos.etiquetas.length > 60 ? 0 : 3,
                    pointHoverRadius: 5,
                    tension: 0.25,
                    spanGaps: true,
                }],
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: false,
                interaction: { mode: "index", intersect: false },
                scales: {
                    y: { min: 0, max: maximo, title: { display: true, text: tituloY } },
                    x: { ticks: { maxTicksLimit: 10, maxRotation: 0 } },
                },
                plugins: {
                    legend: { display: false },
                    bandas: { bandas },
                },
            },
            plugins: [pluginBandas],
        });
    }

    // ---------- Mapa ----------

    function iniciarMapa() {
        mapa = L.map("mapaAire", { scrollWheelZoom: false }).setView([4.86, -74.05], 13);
        L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
            maxZoom: 19,
            attribution: "© OpenStreetMap",
        }).addTo(mapa);
        capaMapa = L.layerGroup().addTo(mapa);
    }

    async function cargarMapa() {
        const datos = await pedir("/api/mapa");
        const ubicaciones = datos.ubicaciones;

        // Llenar el selector una sola vez
        if (!ubicacionesCargadas) {
            const sel = $("selUbicacion");
            ubicaciones.forEach((u) => {
                const op = document.createElement("option");
                op.value = u.codigo;
                op.textContent = u.nombre;
                sel.appendChild(op);
            });
            ubicacionesCargadas = true;
        }

        capaMapa.clearLayers();
        const puntos = [];

        ubicaciones.forEach((u) => {
            const color = u.reciente && u.nivel ? COLOR[u.nivel] : COLOR.viejo;
            const pos = [u.lat, u.lon];
            puntos.push(pos);

            // halo grande y suave: da el efecto de zona de calor
            L.circle(pos, { radius: 220, stroke: false, fillColor: color, fillOpacity: u.reciente ? 0.28 : 0.12 }).addTo(capaMapa);

            const marcador = L.circleMarker(pos, {
                radius: 10, color: "#fff", weight: 2, fillColor: color, fillOpacity: 1,
            }).addTo(capaMapa);

            marcador.bindPopup(
                `<div class="popup-aire"><strong>${esc(u.nombre)}</strong>
                 <span>${esc(u.tipo)} · sensor ${esc(u.sensor)}</span><br>
                 Calidad: <b>${esc(u.nivel || "sin dato")}</b> (${u.puntaje ?? "--"}/100)<br>
                 Gas dominante: ${esc(u.gas_dominante || "--")}<br>
                 <span>${esc(u.fecha)}${u.reciente ? "" : " · " + esc(u.motivo)}</span></div>`
            );
            marcador.on("click", () => seleccionarUbicacion(u.codigo));
        });

        if (primeraCargaMapa && puntos.length) {
            mapa.fitBounds(puntos, { padding: [40, 40] });
            primeraCargaMapa = false;
        }
    }

    // ---------- Eventos ----------

    function seleccionarUbicacion(codigo) {
        estado.ubicacion = codigo;
        $("selUbicacion").value = codigo;
        refrescar();
    }

    async function refrescar() {
        try {
            await cargarEstado();
            // Si no se eligió lugar, la gráfica usa el de la última lectura
            if (!estado.ubicacion) {
                const q = await pedir("/api/estadisticas");
                if (q.estado) {
                    estado.ubicacion = q.estado.ubicacion.codigo;
                    $("selUbicacion").value = "";
                }
            }
            await cargarSerie();
            await cargarMapa();
        } catch (error) {
            console.error("Error al actualizar el panel:", error);
        }
    }

    document.addEventListener("DOMContentLoaded", function () {

        dibujarArcos();
        iniciarMapa();

        $("selUbicacion").addEventListener("change", function (ev) {
            estado.ubicacion = ev.target.value;
            refrescar();
        });

        $("chipsGas").addEventListener("click", function (ev) {
            const b = ev.target.closest(".chip");
            if (!b) return;
            estado.variable = b.dataset.var;
            $("chipsGas").querySelectorAll(".chip").forEach((c) => c.classList.toggle("activo", c === b));
            cargarSerie();
        });

        $("chipsRango").addEventListener("click", function (ev) {
            const b = ev.target.closest(".chip");
            if (!b) return;
            estado.minutos = parseInt(b.dataset.min, 10);
            $("chipsRango").querySelectorAll(".chip").forEach((c) => c.classList.toggle("activo", c === b));
            cargarSerie();
        });

        refrescar();
        setInterval(refrescar, INTERVALO_MS);
    });

})();
