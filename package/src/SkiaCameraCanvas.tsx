import { Canvas, Image, SkImage } from '@shopify/react-native-skia'
import React, { useCallback, useState } from 'react'
import { LayoutChangeEvent, ViewProps } from 'react-native'
import { CameraProps } from './CameraProps'
import { ISharedValue } from 'react-native-worklets-core'
import { useFrameCallback, useSharedValue } from 'react-native-reanimated'

interface SkiaCameraCanvasProps extends ViewProps {
  /**
   * The offscreen textures that have been rendered by the Skia Frame Processor
   */
  offscreenTextures: ISharedValue<SkImage[]>
  /**
   * The resize mode to use for displaying the feed
   */
  resizeMode: CameraProps['resizeMode']
}

export function SkiaCameraCanvas({ offscreenTextures, resizeMode, children, ...props }: SkiaCameraCanvasProps): React.ReactElement {
  const texture = useSharedValue<SkImage | null>(null)
  const [width, setWidth] = useState(0)
  const [height, setHeight] = useState(0)

  useFrameCallback(() => {
    'worklet'

    // 1. atomically pop() the latest rendered frame/texture from our queue
    const latestTexture = offscreenTextures.value.pop()
    if (latestTexture == null) {
      // we don't have a new Frame from the Camera yet, skip this render.
      return
    }

    // 2. dispose the last rendered frame
    texture.value?.dispose()

    // 3. set a new one which will be rendered then
    texture.value = latestTexture
  })

  const onLayout = useCallback(({ nativeEvent: { layout } }: LayoutChangeEvent) => {
    setWidth(Math.round(layout.width))
    setHeight(Math.round(layout.height))
  }, [])

  return (
    <Canvas {...props} onLayout={onLayout}>
      {children}
      <Image x={0} y={0} width={width} height={height} fit={resizeMode} image={texture} />
    </Canvas>
  )
}