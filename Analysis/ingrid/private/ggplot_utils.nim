import macros, tables, strutils, os, sequtils, strformat, options

import ggplotnim
import datamancer
export ggplotnim

import hdf5_utils
import nimhdf5
import arraymancer

import .. / ingrid_types
import geometry, arraymancer_utils, cdl_cuts, cut_utils, fadc_utils

macro echoType(x: typed): untyped =
  echo x.treeRepr

type SupportedRead = float | int | string | bool | Value

proc clusterToDf*(cl: ClusterObject[PixInt], logL, energy, totalCharge, σT: float): DataFrame =
  ## Convertsa given `ClusterObject` into a single row DataFrame for consumption in a
  ## NN that uses its properties as an input.
  ##
  ## Require the diffusion value and total charge for the current run this event corresponds to.
  result = newDataFrame()
  for dset in TPADatasets - {igNumClusters}:
    result[dset.toDset] = newColumn(colFloat, 1)
  result["σT"] = newColumn(colFloat, 1)
  result[igHits.toDset][0]             = cl.hits
  result[igCenterX.toDset][0]          = cl.centerX
  result[igCenterY.toDset][0]          = cl.centerY
  result[igEnergyFromCharge.toDset][0] = energy
  result[igTotalCharge.toDset][0]      = totalCharge
  result[igLikelihood.toDset][0]       = logL
  result["σT"][0]                      = σT / 1000.0 # from μm/√cm to mm/√cm
  for field, val in fieldPairs(cl.geometry):
    result[field][0] = val

proc getDf*(h5f: H5File, path: string, keys: varargs[string]): DataFrame =
  ## read the datasets form `path` in the `h5f` file and combine them to a single
  ## DataFrame
  result = newDataFrame()
  var size = 0
  for key in keys:
    static:
      echoType(key)
    var dsetH5 = h5f[(path / key).dset_str]
    if size == 0:
      size = dsetH5.shape[0]
    withDset(dsetH5):
      when type(dset) is seq[SupportedRead]:
        result[key] = dset

proc readDsets*(h5f: H5FileObj, df: var DataFrame, names: seq[string], baseName: string,
                verbose = true) =
  ## reads the given datasets `names` from `baseName` into the existing `df`
  for name in names:
    let dsetName = baseName / name
    if dsetName in h5f:
      let dsetH5 = h5f[dsetName.dset_str]
      withDset(dsetH5):
        when type(dset) is seq[SupportedRead]:
          df[name] = dset
        elif type(dset) is seq[SomeInteger]:
          df[name] = dset.asType(int)
        elif type(dset) is seq[SomeFloat]:
          df[name] = dset.asType(float)
        else:
          doAssert false, "Invalid datatype for DataFrame! Dtype is " & $(type(dset))
    else:
      if verbose:
        echo &"INFO: Run {baseName} does not have any data for dataset {name}"
  if df.len > 0:
    df["Idx"] = toSeq(0 ..< df.len)

proc readRunDsets*(h5f: H5File, run: int, # path to specific run
                   chipDsets = none[tuple[chip: int, dsets: seq[string]]](),
                   commonDsets: openArray[string] = @[],
                   fadcDsets: openArray[string] = @[],
                   basePath = recoBase(),
                   verbose = true
                  ): DataFrame =
  ## reads all desired datasets `chipDsets, commonDsets` in the given `h5f`
  ## file of `chip` under the given `path`. The result is returned as a
  ## `DataFrame`.
  ##
  ## `chipDsets` are datasets from the chip groups, whereas `commonDsets` are
  ## those from the run group (timestamp, event number, fadcReadout etc). Finally,
  ## `fadcDsets` are those from the FADC.
  ## If input for both is given they are read as individual dataframes, which
  ## are then joined using the eventNumber dataset (which thus will always be
  ## read).
  let path = basePath & $run
  if path notin h5f:
    raise newException(ValueError, "Run " & $run & " does not exist in input file " & $h5f.name & ".")

  let readChip = chipDsets.isSome
  var
    chipDsetNames: seq[string]
    chip: int
    commonDsets = @commonDsets
    fadcDsets = @fadcDsets
    evNumDset = igEventNumber.toDset()
  if readChip:
    chipDsetNames = chipDsets.get.dsets
    if evNumDset notin chipDsetNames and commonDsets.len > 0:
      chipDsetNames.add evNumDset
    if commonDsets.len > 0 and evNumDset notin commonDsets:
      commonDsets.add evNumDset
    if fadcDsets.len > 0 and evNumDset notin fadcDsets:
      fadcDsets.add evNumDset
    chip = chipDsets.get.chip
  var dfChip = newDataFrame()
  var dfAll = newDataFrame()
  var dfFadc = newDataFrame()
  if readChip:
    h5f.readDsets(dfChip, chipDsetNames, path / "chip_" & $chip, verbose = verbose)
  h5f.readDsets(dfAll, commonDsets, path, verbose = verbose)
  h5f.readDsets(dfFadc, fadcDsets, path / "fadc", verbose = verbose)
  proc getFilled(args: varargs[DataFrame]): seq[DataFrame] =
    result = (@args).filterIt(it.len > 0)
  proc numFilled(args: varargs[DataFrame]): int =
    result = getFilled(args).len

  let dfsFilled = numFilled(dfChip, dfAll, dfFadc)
  if dfsFilled == 3:
    # all filled
    result = innerJoin(dfChip, dfAll, evNumDset)
    result = innerJoin(result, dfFadc, evNumDset)
  elif dfsFilled == 2:
    let filled = getFilled(dfChip, dfAll, dfFadc)
    result = innerJoin(filled[0], filled[1], evNumDset)
  elif dfsFilled == 1:
    let filled = getFilled(dfChip, dfAll, dfFadc)
    doAssert filled.len == 1
    result = filled[0]
  else: # no data read
    return newDataFrame()
  result["runNumber"] = run

proc readFilteredFadc*(h5f: H5File): DataFrame =
  let fileInfo = h5f.getFileInfo()
  result = newDataFrame()
  for run in fileInfo.runs:
    if recoBase() & $run / "fadc" notin h5f: continue # skip runs that were without FADC
    var df = h5f.readRunDsets(
      run,
      fadcDsets = @["eventNumber",
                    "baseline",
                    "riseStart",
                    "riseTime",
                    "fallStop",
                    "fallTime",
                    "minVal",
                    "noisy",
                    "argMinval"]
    )
    let xrayRefCuts = getXrayCleaningCuts()
    let runGrp = h5f[(recoBase() & $run).grp_str]
    ## XXX: use different cuts based on photo or escape?
    let tfKind = tfMnCr12 # to determine correct cuts!
    let cut = xrayRefCuts[$tfKind]
    let grp = h5f[(recoBase() & $run / "chip_3").grp_str]
    proc readIdxs(h5f: H5File, grp: H5Group, cut: Cuts, eLow, eHigh: float): seq[int] =
      result = cutOnProperties(
        h5f,
        grp,
        crSilver, # try cutting to silver
        (toDset(igRmsTransverse), cut.minRms, cut.maxRms),
        (toDset(igEccentricity), 0.0, cut.maxEccentricity),
        (toDset(igLength), 0.0, cut.maxLength),
        (toDset(igHits), cut.minPix, Inf),
        (toDset(igEnergyFromCharge), eLow, eHigh)
      )
    let passIdx = concat(@[readIdxs(h5f, grp, cut, 2.5, 3.5), # escapepeak photons
                           readIdxs(h5f, grp, cut, 5.5, 6.5)]) # photopeak photons
      .sorted
    let dfChip = h5f.readRunDsets(run, chipDsets = some((chip: 3, dsets: @["eventNumber"])))
    let allEvNums = dfChip["eventNumber", int]
    let evNums = passIdx.mapIt(allEvNums[it]).toSet
    # filter to allowed events & remove any noisy events
    df = df.filter(f{int: `eventNumber` in evNums and `noisy`.int < 1})
    df["runNumber"] = run
    # which FADC setting was used
    df["Settings"] = $run.toFadcSetting()
    result.add df

proc readRunDsetsAllChips*(h5f: H5File, run: int, # path to specific run
                           chips: seq[int],
                           dsets: seq[string],
                           basePath = recoBase(),
                           verbose = true
                  ): DataFrame =
  ## reads all desired datasets `dsets` for all chips available in this run.
  ## The only common dataset read is the `eventNumber`.
  var dfs = newSeq[DataFrame]()
  for chip in chips:
    var dfLoc = readRunDsets(h5f, run, chipDsets = some((chip: chip, dsets: dsets)),
                             commonDsets = @["eventNumber"],
                             verbose = verbose)
    dfLoc["chip"] = chip
    dfs.add dfLoc
  result = assignStack(dfs)

proc readDsets*(h5f: H5File, path = recoBase(),
                chipDsets = none[tuple[chip: int, dsets: seq[string]]](),
                commonDsets: openArray[string] = @[],
                verbose = true,
                run = -1
               ): DataFrame =
  ## reads all desired datasets `chipDsets, commonDsets` in the given `h5f`
  ## file of `chip` under the given `path`. The result is returned as a
  ## `DataFrame`.
  ##
  ## `chipDsets` are datasets from the chip groups, whereas `commonDsets` are
  ## those from the run group (timestamp, FADC datasets etc)
  ## If input for both is given they are read as individual dataframes, which
  ## are then joined using the eventNumber dataset (which thus will always be
  ## read).
  result = newDataFrame()
  for r, grp in runs(h5f, path):
    if run > 0 and run != r: continue
    let df = h5f.readRunDsets(run = r, chipDsets = chipDsets, commonDsets = commonDsets,
                              basePath = path,
                              verbose = verbose)
    if df.len > 0:
      result.add df

proc readAllDsets*(h5f: H5File, run: int, chip = 3): DataFrame =
  ## Reads all (scalar) datasets of the given run in the file.
  result = h5f.readRunDsets(
    run,
    chipDsets = some((
      chip: chip,
      dsets: concat(getFloatDsetNames().mapIt(it),
                    getIntDsetNames().mapIt(it))))
  )

iterator getDataframes*(h5f: H5File): DataFrame =
  for num, group in runs(h5f):
    for grp in items(h5f, group):
      if "fadc" notin grp.name:
        let chipNum = grp.attrs["chipNumber", int]
        if chipNum == 3:
          yield h5f.readAllDsets(num, chipNum)


defColumn(uint8, uint16)
type
  SeptemDataTable = DataTable[colType(uint8, uint16)]

proc getSeptemDataFrame*(h5f: H5File, runNumber: int, allowedChips: seq[int] = @[],
                         charge = true, ToT = false
                        ): DataFrame = #SeptemDataTable =
  ## Returns a subset data frame of the given `runNumber` and `chipNumber`, which
  ## contains only the zero suppressed event data
  var
    xs, ys: seq[uint8]
    chs: seq[float]
    tots: seq[uint16]
    evs: seq[int]
    cls: seq[int]
    chips = newColumn(colInt)
  let group = recoBase() & $runNumber
  var clusterCount = initCountTable[(int, int)]()
  for run, chip, groupName in chipGroups(h5f):
    if run == runNumber and (allowedChips.len == 0 or chip in allowedChips):
      let grp = h5f[groupName.grp_str]
      let chipNum = grp.attrs["chipNumber", int]
      echo "Reading chip ", chipNum, " of run ", runNumber
      let eventNumbersSingle = h5f[grp.name / "eventNumber", int64]
      var eventNumbers = newSeq[int]()
      var clusters = newSeq[int]()
      let vlenXY = special_type(uint8)
      let vlenCh = special_type(float64)
      # need to read x for shape information (otherwise would need dataset)
      let x = h5f[grp.name / "x", vlenXY, uint8]
      for i in 0 ..< x.len:
        # convert each event into a dataframe
        let event = eventNumbersSingle[i].int
        clusterCount.inc((event, chipNum))
        let count = clusterCount[(event, chipNum)]
        for j in 0 ..< x[i].len:
          eventNumbers.add event
          clusters.add count
      let chipNumCol = constantColumn(chipNum, eventNumbers.len)
      xs.add x.flatten
      ys.add h5f[grp.name / "y", vlenXY, uint8].flatten()
      if charge:
        chs.add h5f[grp.name / "charge", vlenCh, float64].flatten()
      if ToT:
        tots.add h5f[grp.name / "ToT", special_type(uint16), uint16].flatten()
      evs.add(eventNumbers)
      chips = add(chips, chipNumCol)
      cls.add clusters
  result = toDf({ "eventNumber" : evs, "x" : xs.mapIt(it.int), "y" : ys.mapIt(it.int), "chipNumber" : chips,
                  "cluster" : cls })
  #  .to(SeptemDataTable)
  if charge:
    result["charge"] = chs
  if ToT:
    result["ToT"] = tots.mapIt(it.float)

proc getSeptemEventDF*(h5f: H5File, runNumber: int): DataFrame  =
  ## Returns a DataFrame for the given `runNumber`, which contains two columns
  ## the event number and the chip number. This way we can easily extract
  ## which chips had activity on the same event.
  var
    evs, evIdx: seq[int]
    chips: Column
  let group = recoBase() & $runNumber
  for run, chip, groupName in chipGroups(h5f):
    if run == runNumber:
      echo "Reading chip ", chip, " of run ", runNumber
      let
        eventNumbers = h5f[groupName / "eventNumber", int]
        chipNumCol = constantColumn(chip, eventNumbers.len)
        evIndex = toSeq(0 ..< eventNumbers.len)
      evs.add(eventNumbers)
      chips = add(chips, chipNumCol)
      evIdx.add(evIndex)

  result = toDf({"eventIndex" : evIdx, "eventNumber" : evs, "chipNumber" : chips})

#iterator getSeptemDataFrame*(h5f: H5File): SeptemDataTable =
#  for num, group in runs(h5f):
#    let df = h5f.getSeptemDataFrame(num)
#    yield df

proc getChipOutline*(maxVal: SomeNumber): DataFrame =
  ## returns a data frame with only the outline of a Timepix chip as active pixels
  let zeroes = toSeq(0 ..< 256).mapIt(0)
  let maxvals = toSeq(0 ..< 256).mapIt(256)
  let incVals = toSeq(0 ..< 256)
  let xs = concat(zeroes, incVals, maxVals, incVals)
  let ys = concat(incVals, zeroes, incVals, maxvals)
  let ch = constantColumn(maxVal.float, xs.len)
  result = toDf({"x" : xs, "y" : ys, "charge" : ch})

proc getSeptemOutlines*(maxVal: SomeNumber): Tensor[float] =
  ## returns the outline of the chips of the SeptemBoard in a
  ## full septem frame as a Tensor
  result = initSeptemFrame()
  for j in 0 ..< 7:
    let outlineDf = getChipOutline(maxVal)
    result.addChipToSeptemEvent(outlineDf, j)
  result.apply_inline:
      if x > 0.0:
        maxVal / 10.0
      else:
        x

proc getFullFrame*(maxVal: SomeNumber): DataFrame =
  ## returns a data frame with an event similar to a full timepix event, i.e. the
  ## pixels along the pad all full to 4096 pixels (after that cut off)
  let
    xData = toSeq(0 ..< 256)
    yData = toSeq(0 ..< 20)
    comb = product(@[xData, yData])
    ch = constantColumn(maxVal.float, 256 * 20)
  doAssert comb.len == ch.len
  let xy = comb.transpose
  result = toDf({"x" : xy[0], "y": xy[1], "charge" : ch})

proc addChipToSeptemEvent*(occ: var Tensor[float], df: DataFrame, chipNumber: range[0 .. 6],
                           zDset = "charge") =
  doAssert zDset in df, "DataFrame has no key " & $zDset
  # now add values to correct places in tensor
  withSeptemXY(chipNumber):
    let xDf = df["x"].toTensor(int)
    let yDf = df["y"].toTensor(int)
    let zDf = df[zDset].toTensor(float)
    for i in 0 ..< df.len:
      var xIdx, yIdx: int64
      case chipNumber
      of 0, 1, 2, 3, 4:
        xIdx = x0 + xDf[i]
        yIdx = y0 + yDf[i]
      of 5, 6:
        xIdx = x0 - xDf[i]
        yIdx = y0 - yDf[i]
      occ[yIdx.int, xIdx.int] += zDf[i]
    #for i in 0 ..< chip.len:
    # instead of using the data frame, create fake data for now to test arrangment

proc dfToSeptemEvent*(df: DataFrame, zDset = "charge"): DataFrame =
  doAssert zDset in df, "DataFrame has no key " & $zDset
  # now add values to correct places in tensor
  let chipNum = df["chipNumber"].toTensor(int)
  var xDf = df["x"].toTensor(int)
  var yDf = df["y"].toTensor(int)
  let zDf = df[zDset].toTensor(float)
  for i in 0 ..< df.len:
    withSeptemXY(chipNum[i]):
      case chipNum[i]
      of 0, 1, 2, 3, 4:
        xDf[i] = x0 + xDf[i]
        yDf[i] = y0 + yDf[i]
      of 5, 6:
        xDf[i] = x0 - xDf[i]
        yDf[i] = y0 - yDf[i]
      else: doAssert false, "Invalid chip number!"
  result = toDf({"x" : xDf, "y" : yDf, "charge" : zDf})

proc chpPixToRealPix*(df: DataFrame, realLayout = false): DataFrame =
  ## Takes a Septem DataFrame (from `getSeptemDataFrame`) and converts it into a data frame
  ## using the real septem coordinates for all x/y pixels
  var xs = df["x", int]
  var ys = df["y", int]
  let chip = df["chipNumber", int]
  for i in 0 ..< xs.len:
    let pix = chpPixToSeptemPix((x: xs[i], y: ys[i], ch: 0.int), chipNumber = chip[i], realLayout = realLayout)
    xs[i] = pix.x
    ys[i] = pix.y
  result = df
  # overwrite the x and y columns
  result["x"] = xs
  result["y"] = ys

proc drawCircle(x, y: int, radius: float): (seq[float], seq[float]) =
  let xP = linspace(0, 2 * Pi, 1000)
  for i in 0 ..< xP.len:
    result[0].add(x.float + radius * cos(xP[i]))
    result[1].add(y.float + radius * sin(xP[i]))

proc isInside(c: tuple[x, y: float],
              xCenter, yCenter: int, radius: float): bool =
  ## Returns whether the given cluster is inside the circle with given radius.
  result = sqrt( (c.x - xCenter.float)^2 + (c.y - yCenter.float)^2 ) <= radius

proc addSeptemboardOutline*(plt: var GgPlot, useRealLayout: bool) =
  const chipOutlineX = @[
    (x: 0,   yMin: 0, yMax: 255),
    (x: 255, yMin: 0, yMax: 255)
  ]
  const chipOutlineY = @[
    (y: 0  , xMin: 0, xMax: 255),
    (y: 255, xMin: 0, xMax: 255)
  ]
  # dummy data so that not for each `linerange` we walk over the main x/y aesthetics
  # (expensive if large data, e.g. raster of 7 chips)
  let df = toDf({"xs" : @[0, 1], "ys" : @[0, 1], "zs" : @[0, 1]})
  proc toLayout(x: int, isX: bool, chip: int): int =
    result = if useRealLayout: x.chpPixToRealPix(isX, chip) else: x.chpPixToSeptemPix(isX, chip)
  for chip in 0 .. 6:
    for line in chipOutlineX:
      let val  = line.x.toLayout(true, chip)
      let minV = line.yMin.toLayout(false, chip)
      let maxV = line.yMax.toLayout(false, chip)
      plt = plt + geom_linerange(data = df, aes = aes(x = gradient(val), yMin = gradient(minV), yMax = gradient(maxV)))
    for line in chipOutlineY:
      let val  = line.y.toLayout(false, chip)
      let minV = line.xMin.toLayout(true, chip)
      let maxV = line.xMax.toLayout(true, chip)
      plt = plt + geom_linerange(data = df, aes = aes(y = gradient(val), xMin = gradient(minV), xMax = gradient(maxV)))

proc plotSeptemEvent*(evData: PixelsInt, run, eventNumber: int,
                      lines: seq[tuple[m, b: float]],
                      centers: seq[tuple[x, y: float]],
                      xCenter, yCenter: int, radius: float,
                      septemVetoed, lineVetoed: bool, energyCenter: float,
                      useTeX: bool,
                      plotPath: string) =
  ## plots a septem event of the input data for `eventNumber` of `run`.
  ## Shows outlines of the septem chips.
  var xCol = newColumn(colInt, evData.len)
  var yCol = newColumn(colInt, evData.len)
  var chCol = newColumn(colInt, evData.len)
  for i, ev in evData:
    xCol[i] = ev.x
    yCol[i] = ev.y
    chCol[i] = ev.ch
    doAssert ev.ch < 10, "More than 10 clusters indicates something is wrong here. Event: " & $eventNumber & " run: " & $run
  let df = toDf({"x" : xCol, "y" : yCol, "cluster ID" : chCol})

  # create DF for the lines
  proc line(m, b: float, x: float): float =
    result = m * x + b
  var dfLines = newDataFrame()
  var idx = 0
  for l in lines:
    let xs = toSeq(0 .. 767)
    let ys = xs.mapIt(line(l.m, l.b, it.float))
    dfLines.add toDf({"xs" : xs, "ys" : ys, "cluster ID" : idx})
    inc idx

  var dfCenters = newDataFrame()
  idx = 0
  for c in centers:
    let inside = isInside(c, xCenter, yCenter, radius)
    dfCenters.add toDf({"x" : c.x, "y" : c.y, "cluster ID" : idx, "inside?" : inside})
    inc idx

  let (xCircle, yCircle) = drawCircle(xCenter, yCenter, radius)
  let dfCircle = toDf(xCircle, yCircle)

  if plotPath.len > 0:
    createDir(plotPath)

  let csvOutpath = if plotPath.len > 0: plotPath else: "/tmp"
  writeCsv(df, &"{csvOutpath}/septemEvent_run_{run}_event_{eventNumber}.csv")

  ## XXX: make an argument to this proc? Also config.toml and cmdline arg.
  let UseRealLayout = parseBool(getEnv("USE_REAL_LAYOUT", "true"))

  let mTop = getEnv("T_MARGIN", "2.0").parseFloat
  let mBottom = getEnv("B_MARGIN", "2.0").parseFloat
  let mLeft = getEnv("L_MARGIN", "3.0").parseFloat
  let mRight = getEnv("R_MARGIN", "4.0").parseFloat
  let width = getEnv("WIDTH", "640").parseFloat
  proc toPt(x: float): float = x / 2.54 * 72.0
  ## Calculate sizes to have 1:1 aspect ratio of the actual plot.
  ## Explanation:
  ## Our data range is 800 wide, 900 high.
  ## `h = m_T + m_B + p_h` (margins and plot height)
  ## `w = m_L + m_R + p_w` (margins and plot width)
  ## And we want
  ## `p_h = 9 / 8 p_w`
  ## so `p_w = w - m_L - m_R` yielding:
  ##
  ## NOTE: <2023-12-14 Thu> the above is 'outdated' in the sense that it is now part
  ## of `ggplotnim` as `coord_fixed`.

  var height = mTop.topt + mBottom.topt + 9.0 / 8.0 * (width - mLeft.topt - mRight.topt)
  ## If user really wants to overwrite the height as  well, let them
  height = getEnv("HEIGHT", $height).parseFloat
  let outpath = if plotPath.len > 0: plotPath
                else: "plots/septemEvents"

  let newline = if useTeX: r"\\" else: ""
  let title = &"Septem event of event {eventNumber} and run {run}. " &
              &"Center cluster energy: {energyCenter:.2f},{newline} septemVetoed: {septemVetoed}, lineVetoed: {lineVetoed}"
  var plt = ggplot(df, aes(x, y)) +
    geom_point(aes = aes(color = factor("cluster ID")), size = 1.0) +
    xlim(0, 800) + ylim(0, 900) +
    xlab("x [pixel]") + ylab("y [pixel]") +
    scale_x_continuous() + scale_y_continuous() +
    margin(top = mTop, bottom = mBottom, left = mLeft, right = mRight) +
    geom_line(data = dfCircle, aes = aes(x = "xCircle", y = "yCircle")) +
    coord_fixed(1.0) +
    themeLatex(fWidth = 0.9, width = 600, baseTheme = singlePlot, useTeX = useTeX)
  plt.addSeptemboardOutline(UseRealLayout)
  if dfLines.len > 0:
    plt = plt +
      geom_line(data = dfLines, aes = aes(x = "xs", y = "ys", color = factor("cluster ID"))) +
      geom_point(data = dfCenters, aes = aes(x = "x", y = "y", shape = factor("inside?")),
                 color = "red", size = 3.0)
  plt + ggtitle(title) +
    ggsave(&"{outpath}/septemEvent_run_{run}_event_{eventNumber}.pdf",
           useTeX = useTeX, standalone = useTeX, # onlyTikZ = useTeX,
           width = width, height = height)
