const exec = require('child_process').exec
const axios = require('axios')

// ============================================================
// Remote
const targetUrl = 'https://8080-firebase-us-1747877258236.cluster-2xfkbshw5rfguuk5qupw267afs.cloudworkstations.dev'
const ffOpenUrl = 'https://idx.google.com/us-51072006'
// Local
const projectDir = '/home/user/tw'
const vncPassword = 'vevc.firefox.VNC.pwd'
// ============================================================

let lock = false
let errorCount = 0
const containerName = 'idx'

const keepalive = () => {
    console.log(`${new Date().toISOString()}, error: errorCount=${errorCount}`)
    if (errorCount >= 3) {
        lock = true
        errorCount = 0
        console.log(`${new Date().toISOString()}, docker restart, reset errorCount, errorCount=${errorCount}`)
        exec(`docker rm -f ${containerName} && docker run -d --name=${containerName} -e VNC_PASSWORD='${vncPassword}' -e FF_OPEN_URL=${ffOpenUrl} -p 5800:5800 -v ${projectDir}/app/firefox/idx:/config jlesage/firefox`, () => {
            lock = false
        })
    }
}

setInterval(() => {
    axios.get(targetUrl).catch(error => {
        if (error.response) {
            const status = error.response.status
            if (status === 400) {
                errorCount = 0
                console.log(`${new Date().toISOString()}, success, errorCount=${errorCount}`)
            } else {
                errorCount++
                keepalive()
            }
        } else {
            errorCount++
            keepalive()
        }
    })
}, 20000)

// keepalive container
setInterval(() => {
    if (!lock) {
        exec("docker ps --format '{{.Names}}'", (_, stdout) => {
            if (!stdout.includes(containerName)) {
                console.log(`${new Date().toISOString()}, docker recreate ${containerName} to keepalive`)
                exec(`docker rm -f ${containerName} && docker run -d --name=${containerName} -e FF_OPEN_URL=${ffOpenUrl} -e VNC_PASSWORD='${vncPassword}' -p 5800:5800 -v ${projectDir}/app/firefox/idx:/config jlesage/firefox`)
            }
        })
    }
}, 3000)
