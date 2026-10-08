package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"

	"github.com/u-root/u-root/pkg/dt"
)

type profileState string

const (
	profileStock profileState = "stock"
	profilePPS33 profileState = "pps33"
	profilePPS55 profileState = "pps55"
)

type entryLayout struct {
	SocFragmentName     string
	BatteryFragmentName string
	SocOverlay          *dt.Node
	BatteryOverlay      *dt.Node
	CPA                 *dt.Node
	VirtualCP           *dt.Node
	DPDMSwitch          *dt.Node
}

func optionalChild(node *dt.Node, name string) (*dt.Node, bool, error) {
	var result *dt.Node
	for _, candidate := range node.Children {
		if candidate.Name != name {
			continue
		}
		if result != nil {
			return nil, false, fmt.Errorf("node %q has duplicate child %q", node.Name, name)
		}
		result = candidate
	}
	if result == nil {
		return nil, false, nil
	}
	return result, true, nil
}

func child(node *dt.Node, name string) (*dt.Node, error) {
	result, ok, err := optionalChild(node, name)
	if err != nil {
		return nil, err
	}
	if ok {
		return result, nil
	}
	return nil, fmt.Errorf("node %q has no child %q", node.Name, name)
}

func optionalProperty(node *dt.Node, name string) (*dt.Property, bool, error) {
	var result *dt.Property
	for i := range node.Properties {
		if node.Properties[i].Name != name {
			continue
		}
		if result != nil {
			return nil, false, fmt.Errorf("node %q has duplicate property %q", node.Name, name)
		}
		result = &node.Properties[i]
	}
	if result != nil {
		return result, true, nil
	}
	return nil, false, nil
}

func property(node *dt.Node, name string) (*dt.Property, error) {
	result, ok, err := optionalProperty(node, name)
	if err != nil {
		return nil, err
	}
	if ok {
		return result, nil
	}
	return nil, fmt.Errorf("node %q has no property %q", node.Name, name)
}

func u32Property(node *dt.Node, name string) (uint32, error) {
	p, err := property(node, name)
	if err != nil {
		return 0, err
	}
	return p.AsU32()
}

func u32Array(node *dt.Node, name string) ([]uint32, error) {
	p, err := property(node, name)
	if err != nil {
		return nil, err
	}
	if len(p.Value)%4 != 0 {
		return nil, fmt.Errorf("property %q is not a u32 array", name)
	}
	values := make([]uint32, len(p.Value)/4)
	for i := range values {
		values[i] = binary.BigEndian.Uint32(p.Value[i*4 : i*4+4])
	}
	return values, nil
}

func setU32(node *dt.Node, name string, value uint32) {
	node.Update(dt.PropertyU32(name, value))
}

func setU32Array(node *dt.Node, name string, values []uint32) {
	node.Update(dt.PropertyU32Array(name, values))
}

func cloneNode(source *dt.Node) *dt.Node {
	result := &dt.Node{Name: source.Name}
	result.Properties = make([]dt.Property, len(source.Properties))
	for i, p := range source.Properties {
		result.Properties[i] = dt.Property{Name: p.Name, Value: append([]byte(nil), p.Value...)}
	}
	result.Children = make([]*dt.Node, len(source.Children))
	for i, c := range source.Children {
		result.Children[i] = cloneNode(c)
	}
	return result
}

func stringsFromProperty(p *dt.Property) []string {
	parts := bytes.Split(p.Value, []byte{0})
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if len(part) > 0 {
			result = append(result, string(part))
		}
	}
	return result
}

func fragmentForSymbol(root *dt.Node, symbol string, matches func(*dt.Node) bool) (string, *dt.Node, error) {
	fixups, err := child(root, "__fixups__")
	if err != nil {
		return "", nil, err
	}
	p, err := property(fixups, symbol)
	if err != nil {
		return "", nil, err
	}
	var matchedName string
	var matchedOverlay *dt.Node
	for _, fixup := range stringsFromProperty(p) {
		if !strings.HasPrefix(fixup, "/fragment@") || !strings.HasSuffix(fixup, ":target:0") {
			continue
		}
		name := strings.TrimPrefix(strings.SplitN(fixup, ":", 2)[0], "/")
		fragment, err := child(root, name)
		if err != nil {
			return "", nil, err
		}
		overlay, err := child(fragment, "__overlay__")
		if err != nil {
			return "", nil, err
		}
		if !matches(overlay) {
			continue
		}
		if matchedOverlay != nil {
			return "", nil, fmt.Errorf("symbol %q has multiple matching fragments", symbol)
		}
		matchedName, matchedOverlay = name, overlay
	}
	if matchedOverlay == nil {
		return "", nil, fmt.Errorf("symbol %q has no matching fragment", symbol)
	}
	return matchedName, matchedOverlay, nil
}

func inspectLayout(tree *dt.FDT) (*entryLayout, profileState, error) {
	root := tree.RootNode
	model, err := property(root, "model")
	if err != nil || !bytes.Contains(bytes.ToLower(model.Value), []byte("corvette")) {
		return nil, "", fmt.Errorf("entry model is not corvette")
	}
	socName, soc, err := fragmentForSymbol(root, "soc", func(overlay *dt.Node) bool {
		_, cpa, cpaErr := optionalChild(overlay, "oplus,cpa")
		_, cp, cpErr := optionalChild(overlay, "oplus,ufcs_virtual_cp")
		_, dpdm, dpdmErr := optionalChild(overlay, "oplus,virtual_dpdm_switch")
		if cpaErr != nil || cpErr != nil || dpdmErr != nil {
			return false
		}
		return cpa && cp && dpdm
	})
	if err != nil {
		return nil, "", err
	}
	batteryName, battery, err := fragmentForSymbol(root, "battery_charger", func(overlay *dt.Node) bool {
		_, ufcs, ufcsErr := optionalChild(overlay, "oplus,adsp_ufcs")
		_, gauge, gaugeErr := optionalChild(overlay, "oplus,adsp_gauge")
		if ufcsErr != nil || gaugeErr != nil {
			return false
		}
		return ufcs && gauge
	})
	if err != nil {
		return nil, "", err
	}
	cpa, err := child(soc, "oplus,cpa")
	if err != nil {
		return nil, "", err
	}
	virtualCP, err := child(soc, "oplus,ufcs_virtual_cp")
	if err != nil {
		return nil, "", err
	}
	dpdm, err := child(soc, "oplus,virtual_dpdm_switch")
	if err != nil {
		return nil, "", err
	}
	layout := &entryLayout{
		SocFragmentName: socName, BatteryFragmentName: batteryName,
		SocOverlay: soc, BatteryOverlay: battery, CPA: cpa,
		VirtualCP: virtualCP, DPDMSwitch: dpdm,
	}

	charge, hasCharge, chargeErr := optionalChild(soc, "oplus,pps_charge")
	_, hasVirtual, virtualErr := optionalChild(soc, "oplus,virtual_pps")
	_, hasADSP, adspErr := optionalChild(battery, "oplus,adsp_pps")
	if chargeErr != nil || virtualErr != nil || adspErr != nil {
		return nil, "", fmt.Errorf("duplicate PPS nodes detected")
	}
	if !hasCharge && !hasVirtual && !hasADSP {
		return layout, profileStock, nil
	}
	if !(hasCharge && hasVirtual && hasADSP) {
		return nil, "", fmt.Errorf("partial PPS nodes detected")
	}
	curr, err := u32Property(charge, "oplus,curr_max_ma")
	if err != nil {
		return nil, "", err
	}
	switch curr {
	case 3000:
		return layout, profilePPS33, nil
	case 5000:
		return layout, profilePPS55, nil
	default:
		return nil, "", fmt.Errorf("unsupported PPS current: %d", curr)
	}
}

func phandle(node *dt.Node) (uint32, error) {
	p, hasP, err := optionalProperty(node, "phandle")
	if err != nil {
		return 0, err
	}
	lp, hasLP, err := optionalProperty(node, "linux,phandle")
	if err != nil {
		return 0, err
	}
	if !hasP && !hasLP {
		return 0, fmt.Errorf("node %q has no phandle", node.Name)
	}
	var value uint32
	if hasP {
		value, err = p.AsU32()
	} else {
		value, err = lp.AsU32()
	}
	if err != nil {
		return 0, err
	}
	if hasP && hasLP {
		linuxValue, linuxErr := lp.AsU32()
		if linuxErr != nil || linuxValue != value {
			return 0, fmt.Errorf("node %q has inconsistent phandle properties", node.Name)
		}
	}
	return value, nil
}

func maxPhandle(root *dt.Node) (uint32, error) {
	var max uint32
	err := root.Walk(func(node *dt.Node) error {
		for _, name := range []string{"phandle", "linux,phandle"} {
			p, ok, err := optionalProperty(node, name)
			if err != nil {
				return err
			}
			if ok {
				value, err := p.AsU32()
				if err != nil {
					return err
				}
				if value > max {
					max = value
				}
			}
		}
		return nil
	})
	return max, err
}

func insertProtocol(cpa *dt.Node, power uint32) error {
	protocols, err := u32Array(cpa, "oplus,protocol_list")
	if err != nil || len(protocols)%2 != 0 {
		return fmt.Errorf("invalid CPA protocol list")
	}
	insertAt := len(protocols)
	for i := 0; i < len(protocols); i += 2 {
		if protocols[i] == 2 {
			return fmt.Errorf("CPA already contains PPS protocol")
		}
		if protocols[i] == 1 && insertAt == len(protocols) {
			insertAt = i
		}
	}
	protocols = append(protocols, 0, 0)
	copy(protocols[insertAt+2:], protocols[insertAt:len(protocols)-2])
	protocols[insertAt], protocols[insertAt+1] = 2, power
	setU32Array(cpa, "oplus,protocol_list", protocols)

	defaults, err := u32Array(cpa, "oplus,default_protocol_list")
	if err != nil {
		return fmt.Errorf("invalid CPA default protocol list")
	}
	insertAt = len(defaults)
	for i, protocol := range defaults {
		if protocol == 2 {
			return fmt.Errorf("CPA default list already contains PPS protocol")
		}
		if protocol == 1 && insertAt == len(defaults) {
			insertAt = i
		}
	}
	defaults = append(defaults, 0)
	copy(defaults[insertAt+1:], defaults[insertAt:len(defaults)-1])
	defaults[insertAt] = 2
	setU32Array(cpa, "oplus,default_protocol_list", defaults)
	return nil
}

func ensureChild(node *dt.Node, name string) (*dt.Node, error) {
	existing, ok, err := optionalChild(node, name)
	if err != nil {
		return nil, err
	}
	if ok {
		return existing, nil
	}
	created := &dt.Node{Name: name}
	node.Children = append(node.Children, created)
	return created, nil
}

func addLocalFixups(root *dt.Node, layout *entryLayout) error {
	local, err := child(root, "__local_fixups__")
	if err != nil {
		return err
	}
	fragment, err := ensureChild(local, layout.SocFragmentName)
	if err != nil {
		return err
	}
	overlay, err := ensureChild(fragment, "__overlay__")
	if err != nil {
		return err
	}
	for _, name := range []string{"oplus,virtual_pps", "oplus,pps_charge"} {
		_, ok, err := optionalChild(overlay, name)
		if err != nil {
			return err
		}
		if ok {
			return fmt.Errorf("PPS local fixups already exist for %s", name)
		}
	}
	virtual := &dt.Node{Name: "oplus,virtual_pps"}
	virtual.Properties = append(virtual.Properties, dt.PropertyU32("oplus,pps_ic", 0))
	charge := &dt.Node{Name: "oplus,pps_charge"}
	for _, name := range []string{"oplus,pps_ic", "oplus,cp_ic", "oplus,dpdm_switch_ic"} {
		charge.Properties = append(charge.Properties, dt.PropertyU32(name, 0))
	}
	overlay.Children = append(overlay.Children, virtual, charge)
	return nil
}

func updateCurveMaxCurrent(root *dt.Node, value uint32) error {
	return root.Walk(func(node *dt.Node) error {
		for i := range node.Properties {
			p := &node.Properties[i]
			if !strings.HasPrefix(p.Name, "strategy_temp_") || len(p.Value)%20 != 0 {
				continue
			}
			for offset := 8; offset < len(p.Value); offset += 20 {
				if binary.BigEndian.Uint32(p.Value[offset:offset+4]) == 3000 {
					binary.BigEndian.PutUint32(p.Value[offset:offset+4], value)
				}
			}
		}
		return nil
	})
}

func applyProfile(tree, template *dt.FDT, target profileState) error {
	layout, current, err := inspectLayout(tree)
	if err != nil {
		return err
	}
	if current != profileStock {
		return fmt.Errorf("source entry is %s, not stock", current)
	}
	templateLayout, templateState, err := inspectLayout(template)
	if err != nil || templateState != profilePPS33 {
		return fmt.Errorf("invalid PPS template")
	}
	templateCharge, _ := templateLayout.SocOverlay.LookupChildByName("oplus,pps_charge")
	templateVirtual, _ := templateLayout.SocOverlay.LookupChildByName("oplus,virtual_pps")
	templateADSP, _ := templateLayout.BatteryOverlay.LookupChildByName("oplus,adsp_pps")
	charge := cloneNode(templateCharge)
	virtual := cloneNode(templateVirtual)
	adsp := cloneNode(templateADSP)

	max, err := maxPhandle(tree.RootNode)
	if err != nil || max > ^uint32(0)-2 {
		return fmt.Errorf("cannot allocate PPS phandles")
	}
	adspPhandle, virtualPhandle := max+1, max+2
	cpPhandle, err := phandle(layout.VirtualCP)
	if err != nil {
		return err
	}
	dpdmPhandle, err := phandle(layout.DPDMSwitch)
	if err != nil {
		return err
	}
	setU32(adsp, "phandle", adspPhandle)
	setU32(virtual, "phandle", virtualPhandle)
	setU32(virtual, "oplus,pps_ic", adspPhandle)
	setU32(charge, "oplus,pps_ic", virtualPhandle)
	setU32(charge, "oplus,cp_ic", cpPhandle)
	setU32(charge, "oplus,dpdm_switch_ic", dpdmPhandle)

	power := uint32(33)
	if target == profilePPS55 {
		power = 55
		setU32(charge, "oplus,curr_max_ma", 5000)
		setU32(charge, "oplus,pps_strategy_normal_current", 5000)
		setU32(charge, "oplus,pps_ibat_over_third", 7400)
		setU32(charge, "oplus,pps_ibat_over_oplus", 7400)
		setU32(layout.VirtualCP, "oplus,input_curr_max_ma", 5000)
		for _, strategy := range []string{"pps_charge_oplus_strategy", "pps_charge_third_strategy"} {
			node, err := child(charge, strategy)
			if err != nil {
				return err
			}
			if err := updateCurveMaxCurrent(node, 5000); err != nil {
				return err
			}
		}
	}
	if err := insertProtocol(layout.CPA, power); err != nil {
		return err
	}
	if err := addLocalFixups(tree.RootNode, layout); err != nil {
		return err
	}
	layout.SocOverlay.Children = append(layout.SocOverlay.Children, virtual, charge)
	layout.BatteryOverlay.Children = append(layout.BatteryOverlay.Children, adsp)
	return nil
}
