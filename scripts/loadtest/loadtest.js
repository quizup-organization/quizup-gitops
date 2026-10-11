import { check, sleep } from "k6";
import ws from "k6/ws";
import http from "k6/http";
import { Counter } from "k6/metrics";

const BASE = "https://api.quizup.cnadjim.fr";
const WS_URL = "wss://api.quizup.cnadjim.fr/ws/websocket";
const data = JSON.parse(open("./tokens.json"));
const users = data.users;

const wsOpened = new Counter("ws_opened");
const wsErrors = new Counter("ws_errors");
const notificationFrames = new Counter("notification_frames");
const meOk = new Counter("me_ok");
const followOk = new Counter("follow_ok");
const roomsCreated = new Counter("rooms_created");
const answersSent = new Counter("answers_sent");
const duelsFinished = new Counter("duels_finished");
const duelErrors = new Counter("duel_errors");

const MODE = __ENV.MODE || "all";
const SMOKE = __ENV.SMOKE === "1";
const WS_VUS = SMOKE ? 2 : 1000;
const DUEL_VUS = Number(__ENV.DUELS || (SMOKE ? 2 : 100));
const RAMP = Number(__ENV.RAMP || "0"); // duels/s : étale les créations (0 = rafale)
const WS_TIMEOUT = Number(__ENV.WS_TIMEOUT || "600"); // garde-fou par duel WS (s)
const DURATION = SMOKE ? "20s" : "180s";
const FOLLOW_OFFSET = SMOKE ? 100 : 0;
const FOLLOW_COUNT = SMOKE ? 5 : users.length;
const DUEL_OFFSET = 200;

const scenarios = {};
if (MODE !== "games") {
  scenarios.ws_users = {
    executor: "constant-vus",
    vus: WS_VUS,
    duration: DURATION,
    exec: "wsUser",
  };
  scenarios.follow_push = {
    executor: "per-vu-iterations",
    vus: 1,
    iterations: 1,
    exec: "followAll",
    startTime: "20s",
    maxDuration: "150s",
  };
}
if (MODE !== "ws") {
  const rampWindow = RAMP > 0 ? Math.ceil(DUEL_VUS / RAMP) : 0;
  scenarios.duel_bot = {
    executor: "per-vu-iterations",
    vus: DUEL_VUS,
    iterations: 1,
    exec: "duelBot",
    maxDuration: `${rampWindow + WS_TIMEOUT + 60}s`,
    startTime: MODE === "games" ? "0s" : "20s",
  };
}

export const options = {
  scenarios,
  thresholds: {
    duels_finished: MODE === "ws" ? [] : ["count>=1"],
  },
};

export function setup() {
  const res = http.get(`${BASE}/api/topics?size=1&sort=POPULAR`, {
    headers: { Authorization: `Bearer ${data.system.token}` },
  });
  if (res.status !== 200) {
    throw new Error(`topics -> ${res.status}`);
  }
  const topicId = res.json("content.0.topicId");
  console.log(`topic de test: ${topicId}`);
  return { topicId };
}

export function wsUser() {
  const user = users[(FOLLOW_OFFSET + (__VU - 1)) % users.length];
  let logged = 0;
  // Étalement du démarrage : évite la ruée simultanée de 1000 lectures API.
  sleep(Math.random() * 10);
  const res = ws.connect(
    WS_URL,
    { headers: { Origin: "https://app.quizup.cnadjim.fr" } },
    (socket) => {
      socket.on("open", () => {
        wsOpened.add(1);
        socket.send(
          `CONNECT\naccept-version:1.2\nheart-beat:10000,10000\nAuthorization:Bearer ${user.token}\n\n\u0000`,
        );
      });
      socket.on("message", (msg) => {
        if (__ENV.DEBUG === "1" && logged < 5) {
          logged += 1;
          console.log(`VU${__VU} RAW ${JSON.stringify(String(msg).slice(0, 160))}`);
        }
        if (msg.startsWith("CONNECTED")) {
          socket.send(
            `SUBSCRIBE\nid:notif\ndestination:/topic/notifications/${user.userId}\n\n\u0000`,
          );
          socket.send(
            `SUBSCRIBE\nid:presence\ndestination:/topic/presence/${user.userId}\n\n\u0000`,
          );
        } else if (msg.startsWith("MESSAGE")) {
          notificationFrames.add(1);
        } else if (msg.startsWith("ERROR")) {
          wsErrors.add(1);
        }
      });
      socket.on("error", () => wsErrors.add(1));

      const reads = Number(__ENV.READS || "6");
      for (let i = 0; i < reads; i++) {
        const me = http.get(`${BASE}/api/me`, {
          headers: { Authorization: `Bearer ${user.token}` },
        });
        if (me.status === 200) {
          meOk.add(1);
        } else {
          console.log(`VU ${__VU} /api/me -> ${me.status}`);
        }
        sleep(SMOKE ? 3 : 20);
      }
      socket.close();
    },
  );
  check(res, { "ws upgrade 101": (r) => r && r.status === 101 });
}

export function followAll() {
  const headers = {
    Authorization: `Bearer ${data.system.token}`,
    "Content-Type": "application/json",
  };
  for (let i = 0; i < FOLLOW_COUNT; i++) {
    const target = users[(i + FOLLOW_OFFSET) % users.length];
    const res = http.put(`${BASE}/api/profiles/${target.userId}/follow`, null, {
      headers,
    });
    if (res.status === 204 || res.status === 200) {
      followOk.add(1);
    } else {
      console.log(`follow ${i} -> ${res.status}`);
    }
    sleep(0.05);
  }
}

/** POST avec replays : la projection Axon peut exposer l'entité un court instant après la commande. */
function postWithRetry(url, headers, attempts = 12, delaySec = 0.5) {
  let res = null;
  for (let i = 0; i < attempts; i++) {
    res = http.post(url, null, { headers });
    if (res.status === 200 || res.status === 204 || res.status === 409) {
      return res;
    }
    sleep(delaySec);
  }
  return res;
}

/**
 * Duel bot complet en WebSocket (STOMP), comme le client réel : apparition + partie pilotées par
 * les événements poussés (`/topic/rooms/{roomId}` puis `/topic/games/{gameId}`) ; seuls le join
 * de salle, les réponses et le résultat passent en REST.
 */
export function duelBot(topicIdFromSetup) {
  const topicId = topicIdFromSetup?.topicId;
  const user = users[(DUEL_OFFSET + (__VU - 1)) % users.length];
  const headers = {
    Authorization: `Bearer ${user.token}`,
    "Content-Type": "application/json",
  };

  if (RAMP > 0) {
    // Rampe étagée : une création de duel toutes les 1/RAMP seconde.
    sleep(((__VU - 1) % DUEL_VUS) / RAMP);
  }

  const created = http.post(
    `${BASE}/api/rooms/bot`,
    JSON.stringify({ topicId, difficulty: "NORMAL" }),
    { headers },
  );
  if (created.status !== 201) {
    duelErrors.add(1);
    console.log(`room bot ${user.userId} -> ${created.status}`);
    return;
  }
  const roomId = created.json("id");
  roomsCreated.add(1);

  const res = ws.connect(
    WS_URL,
    { headers: { Origin: "https://app.quizup.cnadjim.fr" } },
    (socket) => {
      let gameId = null;
      let ended = false;
      const answeredRounds = {};

      const answerRound = (round) => {
        answeredRounds[round] = true;
        const choice = ["A", "B", "C", "D"][Math.floor(Math.random() * 4)];
        const answer = http.post(
          `${BASE}/api/games/${gameId}/answer`,
          JSON.stringify({ choice }),
          { headers },
        );
        if (answer.status === 200) {
          answersSent.add(1);
        } else {
          console.log(`answer ${gameId} round ${round} -> ${answer.status} ${String(answer.body).slice(0, 140)}`);
        }
      };

      const subscribeGame = () => {
        socket.send(`SUBSCRIBE\nid:game\ndestination:/topic/games/${gameId}\n\n\u0000`);
        // Rattrapage REST : rejoue les événements manqués entre la création et l'abonnement.
        const catchUp = http.get(`${BASE}/api/games/${gameId}/notifications`, { headers });
        if (catchUp.status === 200) {
          const events = catchUp.json() || [];
          console.log(`catch-up ${gameId}: ${events.length} événements`);
          for (const envelope of events) {
            const type = envelope.eventType;
            const payload = envelope.payload || {};
            if (type === "QUESTION_REVEALED" && !answeredRounds[payload.round]) {
              answerRound(payload.round);
            } else if (type === "GAME_ENDED" && !ended) {
              ended = true;
              duelsFinished.add(1);
              http.get(`${BASE}/api/games/${gameId}/result`, { headers });
              socket.close();
            }
          }
        }
      };

      socket.on("open", () => {
        socket.send(
          `CONNECT\naccept-version:1.2\nheart-beat:10000,10000\nAuthorization:Bearer ${user.token}\n\n\u0000`,
        );
        // Heartbeats STOMP (trames "\n") : le broker ferme un client silencieux en ~30 s.
        socket.setInterval(() => socket.send("\n"), 10000);
      });

      socket.on("message", (msg) => {
        if (msg.startsWith("CONNECTED")) {
          socket.send(`SUBSCRIBE\nid:room\ndestination:/topic/rooms/${roomId}\n\n\u0000`);
          // La salle peut ne pas être encore projetée : replays (comme le client web).
          const join = postWithRetry(`${BASE}/api/rooms/${roomId}/join`, headers);
          if (join.status !== 200) {
            duelErrors.add(1);
            console.log(`join room ${roomId} -> ${join.status} ${String(join.body).slice(0, 160)}`);
          }
          return;
        }
        if (!msg.startsWith("MESSAGE")) {
          if (msg.startsWith("ERROR")) {
            wsErrors.add(1);
          }
          return;
        }
        let envelope = null;
        try {
          envelope = JSON.parse(msg.slice(msg.indexOf("\n\n") + 2).replace(/\u0000+$/, ""));
        } catch (error) {
          return;
        }
        const type = envelope.eventType;
        const payload = envelope.payload || {};

        if (type === "ROOM_COMPLETED" && !gameId) {
          gameId = payload.gameId;
          subscribeGame();
        } else if (type === "ROOM_FAILED") {
          duelErrors.add(1);
          console.log(`room failed ${roomId}: ${payload.reason}`);
          socket.close();
        } else if (type === "QUESTION_REVEALED" && gameId && !answeredRounds[payload.round]) {
          // La fenêtre de réponse (10 s) s'ouvre au reveal, pas à l'affichage de la question.
          answerRound(payload.round);
        } else if (type === "GAME_ENDED" && !ended) {
          ended = true;
          duelsFinished.add(1);
          http.get(`${BASE}/api/games/${gameId}/result`, { headers });
          socket.close();
        }
      });

      socket.on("error", () => wsErrors.add(1));

      // Garde-fou : salle jamais complétée ou partie interminable.
      socket.setTimeout(() => {
        if (!ended) {
          duelErrors.add(1);
          console.log(`duel non terminé (room ${roomId}, user ${user.userId})`);
        }
        socket.close();
      }, WS_TIMEOUT * 1000);
    },
  );
  check(res, { "ws upgrade 101": (r) => r && r.status === 101 });
}
