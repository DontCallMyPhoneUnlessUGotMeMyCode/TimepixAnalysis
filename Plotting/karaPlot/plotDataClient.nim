import plotly
import strutils, strformat, tables, sugar, sequtils
import chroma
import jsffi
import json
import dom
import jswebsockets# except Event
include karax / prelude


import components / button

var
  socket = newWebSocket("ws://localhost:8080")

const WIDTH = 800
# global `Plotly` object
let plt = newPlotly()

type
  Messages = enum
    Connected = "Connected"

# proc parseNewData(data: cstring): (JsObject, JsObject, JsObject, JsObject, float, float) =
#   ## given a `DataPacket` received via the socket, parse it to
#   ## a `DataPacket` instance and extract the needed information from it
#   ## and convert it to two `JsObject`
#   let dataPack = parseDataPacket(data)
#   let
#     mnTrace = dataPack.mnTrace
#     mnLayout = dataPack.mnLayout
#     prTrace = dataPack.prTrace
#     prLayout = dataPack.prLayout
#     erValX = dataPack.erValX
#     erValY = dataPack.erValY
#   result[0] = parseJsonToJs("[" & mnTrace & "]")
#   result[1] = parseJsonToJs(mnLayout)
#   result[2] = parseJsonToJs("[" & prTrace & "]")
#   result[3] = parseJsonToJs(prLayout)
#   result[4] = parseFloat(erValX)
#   result[5] = parseFloat(erValY)

# func jsObjectifyPlot(p: Plot): (JsObject, JsObject) =
#   ## given a `Plot` object convert it to two valid `JsObject` to
#   ## send to Plotly
#   result[0] = parseJsonToJs(parseTraces(p.traces))
#   result[1] = parseJsonToJs($(% p.layout))

# proc initPlotly() =
#   ## creates the plotly plot firsts, statically
#   # create the three `Plot` objects we use in the server and client
#   let (p_mnist, p_pred, p_error) = preparePlotly(WIDTH)
#   # load the init data from file and parse it
#   const data = staticRead("resources/init_data.txt")
#   let (mnData, mnLayout, prData, prLayout, erValX, erValY) = parseNewData(data)

#   plt.newPlot("MNIST", mnData, mnLayout)
#   plt.newPlot("prediction", prData, prLayout)
#   let (erData, erLayout) = jsObjectifyPlot(p_error)
#   plt.newPlot("error_rate", erData, erLayout)


# proc animateClient() {.exportc.} =
#   ## create Plotly plots and update them as we reiceve more data
#   ## via a socket. Uses `setInterval` to loop
#   ## This proc is run once the user clicks on the "Start training!" button

#   # send command to server to start the training
#   socket.send($Messages.Train)
#   socket.onMessage = proc (e: MessageEvent) =
#     discard

#   let (p_mnist, p_pred, p_error) = preparePlotly(WIDTH)

#   proc doAgain() =
#     socket.send($Messages.Ping)
#     socket.onMessage = proc (e: MessageEvent) =
#       #echo("received: ", e.data)
#       # parse the data packet to get new data and layout
#       let (mnData, mnLayout, prData, prLayout, erValX, erValY) = parseNewData(e.data)
#       # replace data with new data
#       plt.react("MNIST", mnData, mnLayout)
#       plt.react("prediction", prData, prLayout)
#       # update p_error
#       p_error.traces[0].xs.add erValX
#       p_error.traces[0].ys.add erValY
#       let (errData, errLayout) = jsObjectifyPlot(p_error)
#       plt.react("error_rate", errData, errLayout)

#   discard window.setInterval(doAgain, 400)

proc main() =
  ## main proc of the client (animated plotting using plotly.js). Open a WebSocket,
  ## create plotly `Plot`'s and then wait for data from the socket and update
  ## w/ Plotly.react
  socket.onOpen = proc (e: dom.Event) =
    socket.send($Messages.Connected)
  
  # initialize Plotly (creates static plots)
  # initPlotly()
  proc render(): VNode =
    buildHtml(tdiv):
      head:
        script(src = "https://cdn.plot.ly/plotly-latest.min.js")

      h1(text "test")
      renderButton("TestButton",
                   onClickProc = () => socket.send("Pressed!"))

  setRenderer render

  # animation of the plots is done via the animateClient proc, which is called, once
  # the "Start training!" button is clicked
  # animateClient()

  # when done, close...
  socket.onClose = proc (e:CloseEvent) =
    echo("closing: ",e.reason)


when isMainModule:
  main()
