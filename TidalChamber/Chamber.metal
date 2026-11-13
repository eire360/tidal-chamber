#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position; float4 normal; float4 uvMaterial; };
struct Uniforms {
    float4x4 viewProjection, model, lightProjection;
    float4 cameraTime, lightDay, viewportMotion, renderOptions;
};
struct Raster { float4 position [[position]]; float3 world; float3 normal; float2 uv; float material [[flat]]; float4 shadow; };
float hash31(float3 p) { p=fract(p*0.1031); p+=dot(p,p.yzx+33.33); return fract((p.x+p.y)*p.z); }
float noise3(float3 p) {
    float3 i=floor(p), f=fract(p); f=f*f*(3-2*f);
    return mix(mix(mix(hash31(i),hash31(i+float3(1,0,0)),f.x),mix(hash31(i+float3(0,1,0)),hash31(i+float3(1,1,0)),f.x),f.y),mix(mix(hash31(i+float3(0,0,1)),hash31(i+float3(1,0,1)),f.x),mix(hash31(i+float3(0,1,1)),hash31(i+float3(1,1,1)),f.x),f.y),f.z);
}
float fbm(float3 p) { return noise3(p)*0.55+noise3(p*2.07)*0.25+noise3(p*4.13)*0.13+noise3(p*8.1)*0.07; }
float wave(float2 p,float t) {
    return sin(dot(p,float2(3.1,2.4))+t*0.64)*0.014 + sin(dot(p,float2(-4.3,3.7))-t*0.48)*0.009 + sin(dot(p,float2(8.1,-5.1))+t*0.82)*0.003;
}
float3 waterNormal(float2 p,float t) {
    float2 d=cos(dot(p,float2(3.1,2.4))+t*0.64)*float2(3.1,2.4)*0.014 + cos(dot(p,float2(-4.3,3.7))-t*0.48)*float2(-4.3,3.7)*0.009 + cos(dot(p,float2(8.1,-5.1))+t*0.82)*float2(8.1,-5.1)*0.003;
    d += cos(dot(p,float2(25.7,16.4))+t*0.37)*float2(0.012,0.008);
    float crest=dot(p,float2(2.3,16.5))-t*0.47+sin(p.x*2.1)*0.65;
    d+=cos(crest)*float2(0.001,0.009);
    d+=cos(dot(p,float2(9.1,-43.0))+t*0.31)*float2(0.0005,-0.003);
    return normalize(float3(-d.x,1,-d.y));
}
vertex Raster chamberVertex(uint id [[vertex_id]],const device Vertex* vertices [[buffer(0)]],constant Uniforms& u [[buffer(1)]]) {
    Vertex v=vertices[id]; float4 p=u.model*v.position;
    float3 n=normalize((u.model*v.normal).xyz);
    if(v.uvMaterial.z==3) {
        float t=u.cameraTime.w;
        p.y += wave(p.xz,t);
        // A quiet minute ring, suppressed under Reduce Motion by the host.
        float r=length(p.xz); float age=u.viewportMotion.w;
        float ring=sin(r*32-age*7)*exp(-pow((r-age*0.38)*3,2))*exp(-age*0.7)*0.008*u.viewportMotion.z;
        p.y+=ring; n=waterNormal(p.xz,t);
    }
    Raster o; o.position=u.viewProjection*p; o.world=p.xyz; o.normal=n; o.uv=v.uvMaterial.xy; o.material=v.uvMaterial.z; o.shadow=u.lightProjection*p; return o;
}
vertex float4 shadowVertex(uint id [[vertex_id]],const device Vertex* vertices [[buffer(0)]],constant Uniforms& u [[buffer(1)]]) { return u.lightProjection*u.model*vertices[id].position; }
float shadowAt(float4 p,depth2d<float> map) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,compare_func::less_equal);
    float3 q=p.xyz/p.w; float2 uv=q.xy*float2(0.5,-0.5)+0.5;
    if(any(uv<0)||any(uv>1))return 1;
    float result=0;
    for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++)result+=map.sample_compare(s,uv+float2(x,y)*2.2/1536.0,q.z-0.00045);
    return result/9;
}
float caustic(float2 p,float t) {
    // Smooth interfering wave folds; no uniform Voronoi / honeycomb overlay.
    float2 q=p*1.75;
    q+=float2(sin(q.y*1.7-t*0.12),sin(q.x*1.3+t*0.09))*0.32;
    float a=sin(q.x*3.5+q.y*2.2+sin(q.y*3.1+t*0.13));
    float b=sin(-q.x*2.8+q.y*4.1+cos(q.x*2.1-t*0.17));
    float c=sin(q.x*5.7-q.y*2.6+t*0.11);
    float fold=pow(saturate(1-abs(a+b*0.72+c*0.24)),7.0);
    float broken=smoothstep(0.15,0.65,noise3(float3(p*2.7,t*0.025)));
    return fold*(0.3+broken*0.7);
}
float bedDepth(float2 p) {
    return 0.27+0.67*smoothstep(-1.65,1.2,p.x)+0.26*(1-smoothstep(-1.8,0.6,p.y));
}
float3 perturbHeightNormal(float3 p,float3 n,float h) {
    float3 px=dfdx(p),py=dfdy(p);
    float3 r1=cross(py,n),r2=cross(n,px);
    float det=dot(px,r1);
    if(abs(det)<1e-10)return n;
    float3 gradient=(r1*dfdx(h)+r2*dfdy(h))/det;
    gradient*=min(1.0,0.40/max(length(gradient),0.0001));
    return normalize(n-gradient);
}
fragment float4 chamberFragment(Raster in [[stage_in]],constant Uniforms& u [[buffer(1)]],depth2d<float> shadow [[texture(0)]],texture2d<float> glyph [[texture(1)]]) {
    float3 p=in.world, n=normalize(in.normal), v=normalize(u.cameraTime.xyz-p), l=normalize(u.lightDay.xyz);
    float day=u.lightDay.w, t=u.cameraTime.w;
    float visibility=shadowAt(in.shadow,shadow);
    // Directional aperture: a world-space opening projected along the sun vector.
    // This is art-directed illumination, not an additional fog/render pass.
    float3 projected=p-l*(p.y/max(l.y,0.1));
    float across=dot(projected.xz,normalize(float2(-l.z,l.x)));
    float aperture=0.12+0.88*smoothstep(-4.3,-2.8,across)*(1-smoothstep(1.65,2.5,across));
    float directVisibility=visibility*aperture;
    float3 sun=mix(float3(0.30,0.43,0.65),float3(1.0,0.79,0.50),day);
    float3 ambient=mix(float3(0.055,0.095,0.15),float3(0.12,0.15,0.18),day);
    ambient+=float3(0.07,0.09,0.12)*u.renderOptions.x;
    float3 albedo; float rough=0.8, metal=0;
    if(in.material==0) {
        float3 rockSpace=float3(p.x*0.81+p.z*0.59,p.y*0.94+p.x*0.17,p.z*0.81-p.x*0.59);
        float mineral=fbm(p*0.85), grain=noise3(rockSpace*21);
        float band=sin(p.y*76+sin(p.x*1.3+p.z*0.8)*1.2+noise3(p*2)*1.8);
        float clusters=smoothstep(0.48,0.78,noise3(rockSpace*3.4));
        float pit=smoothstep(0.57,0.88,noise3(rockSpace*43))*clusters;
        float tiny=smoothstep(0.64,0.83,noise3(rockSpace*86));
        float radius=length(p.xz);
        float dialBand=smoothstep(2.16,2.25,radius)*(1-smoothstep(2.46,2.58,radius))*smoothstep(-0.02,0.06,p.y);
        pit*=mix(1.0,0.28,dialBand);
        float height=(grain-0.5)*0.0015-pit*0.004-tiny*0.0003+band*0.001;
        n=perturbHeightNormal(p,n,height);
        albedo=mix(float3(0.46,0.36,0.24),float3(0.76,0.68,0.53),mineral);
        albedo*=0.92+grain*0.14;
        albedo*=1-pit*0.25-tiny*0.035;
        albedo+=float3(0.05,0.025,0.005)*band*0.35;
        float waterline=-0.325+(noise3(float3(p.xz*7,2))-0.5)*0.035;
        float wet=1-smoothstep(waterline-0.05,waterline+0.05,p.y);
        albedo*=mix(float3(1),float3(0.33,0.41,0.39),wet);
        rough=mix(0.88,0.30,wet);
    } else if(in.material==1) { albedo=float3(0.67,0.43,0.16); rough=0.28; metal=0.8;
    } else if(in.material==2) { albedo=float3(0.88,0.78,0.55); rough=0.4; metal=0.2;
    } else if(in.material==4) { albedo=float3(0.075,0.055,0.035); rough=0.95;
    } else if(in.material==5) {
        constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge);
        float alpha=glyph.sample(s,in.uv).a; if(alpha<0.35)discard_fragment();
        albedo=float3(0.065,0.047,0.028); rough=0.95;
    } else {
        // Analytic refraction into a sloping bed, with wavelength-dependent absorption.
        // Approximate light transport; the surface itself remains a displaced mesh.
        n=waterNormal(p.xz,t);
        float3 ray=refract(-v,n,1.0/1.333);
        float depth=bedDepth(p.xz);
        float path=depth/max(-ray.y,0.25);
        float2 bottom=p.xz+ray.xz*path;
        depth=bedDepth(bottom); path=depth/max(-ray.y,0.25);
        bottom=p.xz+ray.xz*path;
        float3 transmission=exp(-float3(2.35,0.85,0.64)*path*2.5);
        float sediment=fbm(float3(bottom*11.5,5));
        float3 bed=mix(float3(0.035,0.075,0.085),float3(0.20,0.23,0.17),sediment);
        float shallow=exp(-depth*2.4);
        float left=1-smoothstep(-0.8,0.65,bottom.x);
        float ca=max(caustic(bottom,t),caustic(bottom*1.43+1.7,-t*0.62)*0.55)*left*shallow*directVisibility*day;
        float3 floorLight=bed*(ambient*0.6+sun*directVisibility*day*1.15);
        floorLight+=float3(0.58,0.65,0.35)*ca*0.88;
        float3 volume=float3(0.0007,0.0025,0.006)*mix(0.45,1.0,day);
        float3 transmitted=floorLight*transmission+volume*(1-transmission);
        float fresnel=0.0204+0.9796*pow(1-saturate(dot(n,v)),5.0);
        float3 reflected=reflect(-v,n);
        // A finite bright opening and dark surrounding rock form broken, broad contours.
        float3 ceiling=p+reflected*((3.5-p.y)/max(reflected.y,0.15));
        float stripA=exp(-pow((ceiling.z+2.0)/0.30,2));
        float stripB=exp(-pow((ceiling.z+0.85)/0.38,2))*0.55;
        float extent=smoothstep(-0.25,0.35,ceiling.x)*(1-smoothstep(2.2,3.1,ceiling.x));
        float opening=(stripA+stripB)*extent;
        float3 environment=mix(float3(0.006,0.013,0.019),float3(0.50,0.63,0.64),opening*day);
        float3 color=mix(transmitted,environment,fresnel);
        color+=environment*opening*0.026*day;
        float glint=pow(saturate(dot(reflect(-l,n),v)),1100)*directVisibility*day;
        color+=sun*glint*0.10;
        float contact=1-smoothstep(1.94,2.12,length(p.xz));
        color*=mix(0.43,1.0,contact)*mix(0.54,1.0,visibility);
        return float4(color/(color+0.65),1);
    }
    float ndl=max(dot(n,l),0.0);
    float3 h=normalize(l+v);
    float spec=pow(max(dot(n,h),0.0),mix(180.0,8.0,rough));
    float3 f0=mix(float3(0.04),albedo,metal);
    float3 diffuse=albedo*(ambient+sun*ndl*directVisibility*mix(0.10,3.3,day))*(1-metal*0.65);
    float3 color=diffuse+f0*spec*sun*directVisibility*2.4;
    // Soft cavity shade makes the modeled cistern wall read as depth.
    if(in.material==0 && length(p.xz)<2.18)color*=0.64;
    // The lower excavation receives cool reflected light, not a second sun.
    float foreground=smoothstep(2.65,4.5,p.z);
    color*=mix(float3(1),float3(0.26,0.37,0.46),foreground);
    return float4(color/(color+0.65),1);
}
