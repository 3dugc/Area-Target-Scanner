Shader "Custom/Wireframe"
{
    Properties
    {
        _WireColor ("Wire Color", Color) = (0, 1, 0.5, 0.6)
        _FillColor ("Fill Color", Color) = (0, 0, 0, 0.05)
    }
    SubShader
    {
        Tags { "Queue"="Transparent" "RenderType"="Transparent" }
        LOD 100
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        Cull Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            float4 _WireColor;
            float4 _FillColor;

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 worldNormal : TEXCOORD0;
                float3 viewDir : TEXCOORD1;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.worldNormal = UnityObjectToWorldNormal(v.normal);
                float3 worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.viewDir = normalize(_WorldSpaceCameraPos - worldPos);
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                // 边缘检测：法线与视线接近垂直时高亮（轮廓线效果）
                float edge = 1.0 - abs(dot(normalize(i.worldNormal), normalize(i.viewDir)));
                edge = pow(edge, 1.5);

                // 混合：边缘区域用线框色，内部用填充色
                float4 col = lerp(_FillColor, _WireColor, smoothstep(0.3, 0.7, edge));
                return col;
            }
            ENDCG
        }
    }
    Fallback "Unlit/Transparent"
}
