"""Independent linear-light metrics and comparison sheet for app/tool output.
Requires Pillow, numpy, scipy. Run after Dart compare_algorithms.dart.
Metrics are viewing-scale proxies, not measurements of a physical panel.
"""
from pathlib import Path
import json
import numpy as np
from scipy.ndimage import gaussian_filter
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'build/quality'
names=['original','floyd','burkes','blueNoise','perceptual']
images={n:Image.open(OUT/f'{n}.png').convert('RGB') for n in names}
def linear(image):
 a=np.asarray(image,dtype=np.float64)/255
 return np.where(a<=.04045,a/12.92,((a+.055)/1.055)**2.4)
source=linear(images['original']);metrics={}
for n in names[1:]:
 diff=linear(images[n])-source
 metrics[n]={}
 for sigma in [1,2,4]:
  filtered=gaussian_filter(diff,(sigma,sigma,0),mode='reflect')
  metrics[n][f'linear_rgb_mse_sigma_{sigma}']=float(np.mean(filtered**2))
# PNG display resampling averages linear light, then encodes back to sRGB.
def display_thumb(image,size):
 a=linear(image);channels=[]
 for ch in range(3):channels.append(np.asarray(Image.fromarray(a[:,:,ch].astype('float32')).resize(size,Image.Resampling.BOX)))
 a=np.stack(channels,axis=2);s=np.where(a<=.0031308,12.92*a,1.055*np.maximum(a,0)**(1/2.4)-.055)
 return Image.fromarray((s.clip(0,1)*255+.5).astype('uint8'))
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',19)
small=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',14)
canvas=Image.new('RGB',(1600,650),'#f5f4ef');draw=ImageDraw.Draw(canvas)
labels=['原图','Floyd–Steinberg','Burkes','蓝噪声覆盖','DBS 感知重建']
for i,n in enumerate(names):
 draw.text((i*320+12,16),labels[i],fill='#203d3b',font=font)
 canvas.paste(display_thumb(images[n],(304,219)),(i*320+8,55))
 # Fixed face detail in the letterboxed 768x552 output; shared crop for all modes.
 crop=images[n].crop((280,70,430,220)).resize((300,300),Image.Resampling.NEAREST)
 canvas.paste(crop,(i*320+10,308))
 draw.text((i*320+12,282),'局部像素 ×2（未平滑）',fill='#78817c',font=small)
draw.text((12,622),'测试照片：NASA / scikit-image astronaut（公共领域）；仅软件对比，非实体屏实拍。',fill='#203d3b',font=small)
canvas.save(OUT/'comparison.png')
(OUT/'metrics.json').write_text(json.dumps(metrics,indent=2),encoding='utf-8')
print(json.dumps(metrics,indent=2))
