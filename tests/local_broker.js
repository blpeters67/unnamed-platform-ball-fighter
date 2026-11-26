// Local MQTT-over-WebSocket broker for netplay tests (npm i aedes@0.51 websocket-stream@5).
// node tests/local_broker.js, then run two games with -- --nettest=host:CAFE / join:CAFE --signal=ws://127.0.0.1:9011/mqtt
const aedes = require('aedes')()
const http = require('http')
const ws = require('websocket-stream')
const server = http.createServer()
ws.createServer({ server }, aedes.handle)
server.listen(9011, '127.0.0.1', () => console.log('mqtt ws on 9011'))
aedes.on('publish', (p, c) => { if (c && !p.topic.endsWith('/d')) console.log('pub', p.topic, p.retain ? 'R' : '', p.payload.length) })
